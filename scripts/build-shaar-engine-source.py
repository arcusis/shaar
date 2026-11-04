#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Build and verify the Shaar layer in a separate Chromium source tree.

The temporary dual-export mode clones a succeeded pinned source checkout with
APFS copy-on-write. The reference is read only; every generated file and build
artifact stays under build/ShaarEngineSource. A dry run performs no writes.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile


CONFIG = Path("ThirdParty/ChromiumEngine/source-build.json")
LAYER = Path("ThirdParty/ChromiumEngine/layer")
OUTPUT = Path("build/ShaarEngineSource")
OWNER_FILE = ".shaar-source-owner.json"
RECEIPT_FILE = "receipt.json"
REQUIRED_EXPORTS = (
    "_shaar_abi_major",
    "_shaar_abi_minor",
    "_shaar_engine_create",
    "_shaar_engine_run",
    "_shaar_engine_request_quit",
    "_shaar_engine_release",
    "_shaar_submit",
    "_shaar_cancel_request",
    "_shaar_profile_open",
    "_shaar_profile_create",
    "_shaar_profile_close",
    "_shaar_profile_delete",
    "_shaar_profile_get_state",
    "_shaar_profile_set_state",
    "_shaar_profile_get_path",
    "_shaar_private_session_open",
    "_shaar_private_session_close",
    "_shaar_private_session_cookie_setting",
    "_shaar_window_open",
    "_shaar_window_close",
    "_shaar_tab_open",
    "_shaar_tab_close",
    "_shaar_window_host_view",
    "_shaar_window_native_window",
    "_shaar_tab_host_view",
    "_shaar_tab_view_attach",
    "_shaar_tab_view_detach",
    "_shaar_tab_view_focus",
    "_shaar_window_host_resize",
    "_shaar_site_security_info",
)
PROFILE_MODULE_EXPORTS = (
    "_shaar_profile_open",
    "_shaar_profile_create",
    "_shaar_profile_close",
    "_shaar_profile_delete",
    "_shaar_profile_get_state",
    "_shaar_profile_set_state",
    "_shaar_profile_get_path",
)
PROFILE_MODULE_LAYER_FILES = (
    "chrome/browser/shaar/BUILD.gn",
    "chrome/browser/shaar/engine/shaar_engine_context.cc",
    "chrome/browser/shaar/engine/shaar_engine_context.h",
    "chrome/browser/shaar/engine/shaar_module_registry.h",
    "chrome/browser/shaar/lifecycle/shaar_module_registry.cc",
    "chrome/browser/shaar/profiles/shaar_profiles.cc",
    "chrome/browser/shaar/profiles/shaar_profiles.h",
    "chrome/browser/shaar/profiles/shaar_profiles_unittest.cc",
)
EXTENSIONS_MODULE_LAYER_FILES = (
    "chrome/browser/shaar/BUILD.gn",
    "chrome/browser/shaar/extensions/shaar_extensions.cc",
    "chrome/browser/shaar/extensions/shaar_extensions.h",
    "chrome/browser/shaar/extensions/shaar_extensions_lifecycle_adapter.cc",
    "chrome/browser/shaar/extensions/shaar_extensions_unittest.cc",
    "chrome/browser/shaar/lifecycle/shaar_module_registry.cc",
    "chrome/browser/shaar/public/shaar_engine.h",
)
COMMIT = re.compile(r"[0-9a-f]{40}\Z")
DIGEST = re.compile(r"[0-9a-f]{64}\Z")


class BuildError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def layer_files(root: Path) -> dict[str, str]:
    if not root.is_dir() or root.is_symlink():
        raise BuildError("Shaar layer directory is absent or a symlink")
    files = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise BuildError(f"symlink rejected in Shaar layer: {path}")
        if path.is_file():
            files[path.relative_to(root).as_posix()] = sha256(path)
    return files


def layer_digest(files: dict[str, str]) -> str:
    digest = hashlib.sha256()
    for name, file_digest in sorted(files.items()):
        digest.update(name.encode("utf-8") + b"\0" + file_digest.encode("ascii") + b"\n")
    return digest.hexdigest()


def checked_repo_file(repo: Path, relative: str) -> Path:
    path = Path(relative)
    if path.is_absolute() or ".." in path.parts or not path.parts:
        raise BuildError(f"unsafe source input path: {relative}")
    current = repo
    for part in path.parts:
        current = current / part
        if current.is_symlink():
            raise BuildError(f"symlink rejected in source input: {relative}")
    if not current.is_file():
        raise BuildError(f"missing source input: {relative}")
    return current


def guarded_output(repo: Path) -> Path:
    repo = repo.resolve(strict=True)
    current = repo
    for part in OUTPUT.parts:
        current = current / part
        if current.is_symlink():
            raise BuildError(f"symlink rejected in output path: {current}")
    if current.exists() and not current.is_dir():
        raise BuildError("Shaar output is not a directory")
    if current.parent.exists() and not current.parent.is_dir():
        raise BuildError("Shaar output parent is not a directory")
    return current


def owned_child(output: Path, relative: str) -> Path:
    current = output
    for part in Path(relative).parts:
        current = current / part
        if current.is_symlink():
            raise BuildError(f"symlink rejected inside Shaar output: {current}")
    return current


def owner_record(repo: Path) -> dict:
    repo = repo.resolve(strict=True)
    return {"schemaVersion": 1, "sourceKind": "shaar", "uid": os.getuid(),
            "repo": str(repo), "output": str(repo / OUTPUT)}


def prepare_owned_output(repo: Path) -> Path:
    """Create or validate the private, unindexed Shaar build output."""
    output = guarded_output(repo)
    expected = owner_record(repo)
    if output.exists():
        if output.stat().st_uid != os.getuid() or stat.S_IMODE(output.stat().st_mode) & 0o077:
            raise BuildError("Shaar output ownership or mode rejected")
        owner = output / OWNER_FILE
        if owner.is_symlink() or not owner.is_file() or json.loads(owner.read_text()) != expected:
            raise BuildError("Shaar output owner record mismatch")
        marker = output / ".metadata_never_index"
        if marker.is_symlink():
            raise BuildError("symlinked Spotlight exclusion in Shaar output")
        marker.touch(exist_ok=True)
        return output
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.parent.is_symlink():
        raise BuildError("Shaar output parent became a symlink")
    output.mkdir(mode=0o700)
    os.chmod(output, 0o700)
    owner = output / OWNER_FILE
    fd = os.open(owner, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(expected, stream, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    (output / ".metadata_never_index").touch()
    return output


def load_config(repo: Path) -> dict:
    repo = repo.resolve(strict=True)
    config = json.loads(checked_repo_file(repo, CONFIG.as_posix()).read_text())
    if config.get("schemaVersion") != 1 or config.get("sourceKind") != "shaar":
        raise BuildError("Shaar source config identity mismatch")
    if config.get("build", {}).get("output") != OUTPUT.as_posix():
        raise BuildError("Shaar output root must be build/ShaarEngineSource")
    if config["build"].get("target") != "chrome_framework":
        raise BuildError("unexpected framework target")
    expected_binary = (
        "chromium_git/chromium/src/out/Release_GN_arm64/"
        f"Chromium Framework.framework/Versions/{config['chromium']['version']}/Chromium Framework"
    )
    if config["build"].get("frameworkBinary") != expected_binary:
        raise BuildError("unexpected framework binary path")
    for section, field in (
        ("chromium", "commit"), ("ungoogled", "commit"),
        ("ungoogled", "macosCommit"), ("depotTools", "commit"),
    ):
        if not COMMIT.fullmatch(config[section][field]):
            raise BuildError(f"invalid pinned commit {section}.{field}")
    if not DIGEST.fullmatch(config["gitLfs"]["archiveSha256"]):
        raise BuildError("invalid Git LFS archive digest")
    if "source" in config or "latest" in json.dumps(config).lower():
        raise BuildError("floating or legacy source input rejected")
    if "mantrakp04/ardia" in json.dumps(config).lower():
        raise BuildError("legacy source repository rejected")

    actual_files = layer_files(repo / LAYER)
    recorded = config.get("layer", {})
    if (recorded.get("path") != LAYER.as_posix() or
            actual_files != recorded.get("files") or
            layer_digest(actual_files) != recorded.get("sha256")):
        raise BuildError("Shaar layer manifest or tree digest mismatch")
    exports = checked_repo_file(repo, (LAYER / "chrome/browser/shaar/shaar_engine.exports").as_posix())
    if tuple(exports.read_text().splitlines()) != REQUIRED_EXPORTS:
        raise BuildError("Shaar export list differs from step-0 ABI")
    if config.get("requiredExports") != list(REQUIRED_EXPORTS):
        raise BuildError("required export receipt list mismatch")
    if config.get("moduleBlocks", {}).get("profiles") != {
        "operationRange": [100, 199],
        "layerFiles": list(PROFILE_MODULE_LAYER_FILES),
        "requiredExports": list(PROFILE_MODULE_EXPORTS),
    }:
        raise BuildError("profiles module block is missing or inconsistent")
    if config.get("moduleBlocks", {}).get("extensions") != {
        "operationRange": [800, 899],
        "moduleID": 1300,
        "layerFiles": list(EXTENSIONS_MODULE_LAYER_FILES),
        "requiredExports": [],
    }:
        raise BuildError("extensions module block is missing or inconsistent")

    patches = config.get("patches")
    if not isinstance(patches, list) or not patches:
        raise BuildError("Shaar patch manifest is empty")
    for patch in patches:
        if not DIGEST.fullmatch(patch.get("sha256", "")):
            raise BuildError("invalid Shaar patch digest")
        path = checked_repo_file(repo, patch["file"])
        if not patch["file"].startswith("ThirdParty/ChromiumEngine/patches/"):
            raise BuildError("patch outside Shaar-owned directory")
        if sha256(path) != patch["sha256"]:
            raise BuildError(f"Shaar patch digest mismatch: {patch['file']}")
    dual_patch = config.get("dualExportPatch", {})
    if (not dual_patch.get("file", "").startswith("ThirdParty/ChromiumEngine/patches/") or
            not DIGEST.fullmatch(dual_patch.get("sha256", ""))):
        raise BuildError("invalid dual-export delegate patch")
    dual_path = checked_repo_file(repo, dual_patch["file"])
    if sha256(dual_path) != dual_patch["sha256"]:
        raise BuildError("Shaar dual-export delegate patch digest mismatch")
    guarded_output(repo)
    return config


def dry_run(repo: Path, config: dict) -> dict:
    return {
        "sourceKind": "shaar",
        "execution": "dry-run; --run requires a pinned, succeeded reference source checkout",
        "output": str(guarded_output(repo)),
        "configuration": config["build"]["configuration"],
        "target": config["build"]["target"],
        "chromiumCommit": config["chromium"]["commit"],
        "layerSha256": config["layer"]["sha256"],
        "patches": [config["patches"][0]["file"], config["dualExportPatch"]["file"]],
        "stages": [
            "copy-on-write snapshot of pinned dual-export Chromium and depot_tools",
            "ordered Shaar patches",
            "verified Shaar layer installation at chrome/browser/shaar",
            "GN generation for chrome_framework",
            "framework build and export receipt verification",
            "headless Swift loader ABI-major probe",
            "optional --layer-tests target build and gtest JSON run",
        ],
        "requiredExports": config["requiredExports"],
        "finalTargetForbiddenExports": ["ac_*", "ArdiaCore*"],
        "temporaryMode": "dual-export; Ardia remains only in the development snapshot",
    }


def check_exports(symbols: str, all_symbols: str | None = None,
                  mode: str = "final") -> dict:
    """Validate external exports and all named symbols in the final binary."""
    found = set(symbols.splitlines())
    missing = sorted(set(REQUIRED_EXPORTS) - found)
    all_names = {line.split()[-1] for line in (all_symbols or symbols).splitlines() if line.split()}
    forbidden = sorted(name for name in (found | all_names)
                       if name.startswith(("_ac_", "ac_")) or "ArdiaCore" in name)
    if missing:
        raise BuildError("missing Shaar framework exports: " + ", ".join(missing))
    if mode == "final" and forbidden:
        raise BuildError("legacy framework exports present: " + ", ".join(forbidden))
    if mode == "dual-export" and "_ac_engine_abi_version" not in found:
        raise BuildError("dual-export framework lacks pinned Ardia ABI export")
    if mode not in ("final", "dual-export"):
        raise BuildError("unknown export verification mode")
    return {"required": list(REQUIRED_EXPORTS), "legacyFound": forbidden,
            "exportedSymbolCount": len(found), "allSymbolCount": len(all_names)}


def verify_framework(repo: Path, binary: Path, receipt: Path, config: dict,
                     mode: str = "final") -> dict:
    """Post-build hook: fail before recording a framework with wrong exports."""
    output = guarded_output(repo)
    if not output.is_dir() or output.is_symlink():
        raise BuildError("Shaar output does not exist")
    if output.stat().st_uid != os.getuid() or stat.S_IMODE(output.stat().st_mode) & 0o077:
        raise BuildError("Shaar output ownership or mode rejected")
    owner = output / OWNER_FILE
    if owner.is_symlink() or not owner.is_file() or json.loads(owner.read_text()) != owner_record(repo):
        raise BuildError("Shaar output owner record mismatch")
    if binary != output / config["build"]["frameworkBinary"] or receipt != output / RECEIPT_FILE:
        raise BuildError("framework or receipt path does not match Shaar build layout")
    for path in (binary, receipt):
        try:
            relative = path.relative_to(output)
        except ValueError as exc:
            raise BuildError("framework or receipt outside Shaar output") from exc
        current = output
        for part in relative.parts:
            current = current / part
            if current.is_symlink():
                raise BuildError("symlink rejected in framework or receipt path")
    if not binary.is_file():
        raise BuildError("framework binary missing")
    exported = subprocess.run(["/usr/bin/nm", "-gUj", str(binary)], check=True,
                              capture_output=True, text=True, timeout=120)
    all_symbols = subprocess.run(["/usr/bin/nm", "-a", str(binary)], check=True,
                                 capture_output=True, text=True, timeout=120)
    exports = check_exports(exported.stdout, all_symbols.stdout, mode)
    record = {
        "schemaVersion": 1,
        "sourceKind": "shaar",
        "mode": mode,
        "status": "exports_verified" if mode == "dual-export" else "succeeded",
        "output": str(output),
        "configSha256": sha256(repo / CONFIG),
        "layerSha256": config["layer"]["sha256"],
        "framework": {
            "binary": str(binary.relative_to(output)),
            "sha256": sha256(binary),
            "exports": exports,
        },
    }
    write_receipt(receipt, record)
    return record


def write_receipt(receipt: Path, record: dict) -> None:
    if not receipt.parent.is_dir() or receipt.is_symlink():
        raise BuildError("unsafe receipt path")
    temporary = receipt.with_name(receipt.name + ".tmp")
    if temporary.exists() or temporary.is_symlink():
        raise BuildError("stale or unsafe receipt temporary path")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(record, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, receipt)
        os.chmod(receipt, 0o600)
    finally:
        temporary.unlink(missing_ok=True)


def now_utc() -> str:
    return datetime.now(timezone.utc).isoformat()


def validate_reference(repo: Path, reference: Path, output: Path,
                       config: dict) -> tuple[Path, Path, dict]:
    """Accept only a completed build of the same pinned Chromium checkout."""
    source = reference.resolve(strict=True)
    if source.name != "src" or source.parent.name != "chromium":
        raise BuildError("reference must be the pinned chromium/src checkout")
    reference_root = source.parents[2]
    if output == reference_root or output in reference_root.parents or reference_root in output.parents:
        raise BuildError("reference and Shaar output roots must be disjoint")
    if source.stat().st_dev != repo.stat().st_dev:
        raise BuildError("copy-on-write snapshot requires the same APFS volume")
    reference_receipt = reference_root / RECEIPT_FILE
    if not reference_receipt.is_file() or reference_receipt.is_symlink():
        raise BuildError("reference build receipt missing")
    reference_record = json.loads(reference_receipt.read_text())
    if reference_record.get("status") != "succeeded":
        raise BuildError("reference source build has not succeeded")
    for section in ("chromium", "ungoogled", "depotTools"):
        if reference_record.get("pins", {}).get(section) != config[section]:
            raise BuildError(f"reference {section} pins differ from Shaar config")
    legacy_pin = json.loads(checked_repo_file(
        repo, "ThirdParty/ArdiaCore/source-build.json").read_text())["source"]
    if reference_record.get("pins", {}).get("source") != legacy_pin:
        raise BuildError("reference Ardia pin differs from the pre-relicense source")
    head = subprocess.run(["git", "-C", str(source), "rev-parse", "HEAD"],
                          check=True, capture_output=True, text=True, timeout=30).stdout.strip()
    if head != config["chromium"]["commit"]:
        raise BuildError("reference Chromium checkout differs from pin")
    if not (source / "out" / config["build"]["configuration"] / "args.gn").is_file():
        raise BuildError("reference GN args missing")
    if not (reference_root / "depot_tools/autoninja").is_file():
        raise BuildError("reference depot_tools missing")
    if not (reference_root / config["build"]["frameworkBinary"]).is_file():
        raise BuildError("reference framework missing")
    return source, reference_root, reference_record


def run_logged(command: list[str], cwd: Path, log: Path, *, env: dict[str, str] | None = None,
               timeout: int = 43200) -> None:
    display = " ".join(command)
    if len(display) > 240:
        display = display[:237] + "..."
    print(f"running: {display}; log: {log}", flush=True)
    with log.open("w") as stream:
        result = subprocess.run(command, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT,
                                env=env, timeout=timeout, check=False)
    if result.returncode:
        raise BuildError(f"command failed ({result.returncode}): {display}; see {log}")


def clear_stale_siso_lock(copied_out: Path) -> None:
    lock = copied_out / ".siso_lock"
    if lock.is_symlink():
        raise BuildError("symlinked Siso lock in Shaar output")
    if lock.exists():
        match = re.fullmatch(r"pid=(\d+)\s*", lock.read_text())
        if not match:
            raise BuildError("unrecognized Siso lock in Shaar output")
        try:
            os.kill(int(match.group(1)), 0)
        except ProcessLookupError:
            lock.unlink()
        except PermissionError as exc:
            raise BuildError("cannot verify Siso lock owner") from exc
        else:
            raise BuildError("a Siso build still owns the Shaar output")
    for stale_log in copied_out.glob("siso*.INFO"):
        if stale_log.is_symlink():
            stale_log.unlink()


def snapshot_source(output: Path, source: Path, reference_root: Path, config: dict,
                    receipt: Path, record: dict) -> Path:
    destination = owned_child(output, "chromium_git/chromium/src")
    depot = owned_child(output, "depot_tools")
    marker = output / ".source-snapshot.json"
    if marker.exists():
        snapshot = json.loads(marker.read_text())
        if (marker.is_symlink() or not destination.is_dir() or
                snapshot.get("reference") != str(source) or
                snapshot.get("chromiumCommit") != config["chromium"]["commit"] or
                snapshot.get("referenceReceiptSha256") != record["referenceReceiptSha256"]):
            raise BuildError("existing Shaar source snapshot does not match reference")
        clear_stale_siso_lock(destination / "out" / config["build"]["configuration"])
        return destination
    if destination.exists() or depot.exists():
        raise BuildError("incomplete Shaar source snapshot; refusing to overwrite")
    destination.parent.mkdir(parents=True, exist_ok=True)
    run_logged(["/bin/cp", "-cR", str(source), str(destination)], output,
               output / "source-copy.log", timeout=config["build"]["timeoutsSeconds"]["sync"])
    run_logged(["/bin/cp", "-cR", str(reference_root / "depot_tools"),
                str(depot)], output, output / "tools-copy.log", timeout=1800)
    shutil.copy2(reference_root / "chromium_git/chromium/.gclient",
                 output / "chromium_git/chromium/.gclient")
    own_gclient = output / "chromium_git/chromium/.gclient"
    own_gclient.write_text(own_gclient.read_text().replace(
        str(reference_root / "gclient-cache"), str(output / "gclient-cache")))
    copied_head = subprocess.run(["git", "-C", str(destination), "rev-parse", "HEAD"],
                                 check=True, capture_output=True, text=True, timeout=30).stdout.strip()
    if copied_head != config["chromium"]["commit"]:
        raise BuildError("copied Chromium checkout differs from pin")
    copied_out = destination / "out" / config["build"]["configuration"]
    clear_stale_siso_lock(copied_out)
    marker_record = {"reference": str(source), "chromiumCommit": config["chromium"]["commit"],
                     "referenceReceiptSha256": record["referenceReceiptSha256"],
                     "completedAt": now_utc()}
    write_receipt(marker, marker_record)
    return destination


def install_layer(repo: Path, source: Path, config: dict) -> None:
    target = source / "chrome/browser/shaar"
    if target.exists() or target.is_symlink():
        installed = {"chrome/browser/shaar/" + name: digest
                     for name, digest in layer_files(target).items()}
        if installed != config["layer"]["files"]:
            raise BuildError("existing installed Shaar layer differs from manifest")
    else:
        shutil.copytree(repo / LAYER / "chrome/browser/shaar", target)
    for entry in (config["patches"][0], config["dualExportPatch"]):
        patch = repo / entry["file"]
        checked = subprocess.run(["git", "apply", "--check", str(patch)], cwd=source,
                                 capture_output=True, text=True, timeout=60)
        if checked.returncode == 0:
            subprocess.run(["git", "apply", str(patch)], cwd=source, check=True, timeout=60)
        else:
            reverse = subprocess.run(["git", "apply", "--reverse", "--check", str(patch)],
                                     cwd=source, capture_output=True, text=True, timeout=60)
            if reverse.returncode:
                raise BuildError(f"Shaar patch neither applies nor matches installed source: {patch}")


def ninja_command(ninja: Path, out: Path, target: str) -> str:
    """Read the last GN-generated command for one target without building it."""
    process = subprocess.Popen([str(ninja), "-C", str(out), "-t", "commands", target],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, errors="replace")
    last = ""
    count = 0
    assert process.stdout is not None and process.stderr is not None
    for line in process.stdout:
        last = line.strip()
        count += 1
    errors = process.stderr.read()
    if process.wait(timeout=180) or not last or count == 0:
        raise BuildError(f"cannot read GN command for {target}: {errors[-500:]}")
    return last


def link_inputs_and_variables(out: Path) -> tuple[list[str], dict[str, str]]:
    target = out / "obj/chrome/chrome_framework_shared_library.ninja"
    lines = target.read_text().splitlines()
    prefix = "build obj/chrome/chrome_framework_shared_library/Chromium$ Framework "
    edges = [line for line in lines if line.startswith(prefix) and ": solink " in line]
    if len(edges) != 1:
        raise BuildError("GN framework link edge missing or ambiguous")
    raw = edges[0].split(": solink ", 1)[1].split(" | ", 1)[0]
    paths = [part.replace("\0", " ") for part in
             raw.replace("$ ", "\0").split()]
    if len(paths) < 10000 or any("$" in part or Path(part).is_absolute() for part in paths):
        raise BuildError("unexpected GN framework link input list")
    expected_shaar = {
        "obj/chrome/browser/shaar/engine/shaar_engine.o",
        "obj/chrome/browser/shaar/engine/shaar_event_bridge.o",
    }
    if not expected_shaar.issubset(paths):
        raise BuildError("Shaar objects missing from GN framework link inputs")
    variables = {key.strip(): value.strip() for line in lines[1:]
                 if " = " in line for key, value in [line.split(" = ", 1)]}
    for key in ("frameworks", "swiftmodules", "solibs", "libs"):
        if "$" in variables.get(key, ""):
            raise BuildError(f"unexpanded GN link variable: {key}")
    return paths, variables


def relink_from_reference_objects(output: Path, source: Path, config: dict,
                                  env: dict[str, str]) -> dict:
    """Build only new Shaar objects, then use the pinned completed object graph."""
    out = source / "out" / config["build"]["configuration"]
    ninja = source / "third_party/ninja/ninja"
    if not ninja.is_file() or not (out / "obj/build/modules/system/module.pcm").is_file():
        raise BuildError("pinned compiler prerequisites missing")
    objects = (
        "obj/chrome/browser/shaar/engine/shaar_engine.o",
        "obj/chrome/browser/shaar/engine/shaar_event_bridge.o",
    )
    for index, target in enumerate(objects):
        command = ninja_command(ninja, out, target)
        if (not command.startswith("../../third_party/llvm-build/Release+Asserts/bin/clang++ ")
                or f"-o {target}" not in command or " -c ../../chrome/browser/shaar/engine/" not in command):
            raise BuildError(f"unexpected GN compile command for {target}")
        run_logged(["/usr/sbin/taskpolicy", "-b", "/bin/sh", "-c", command], out,
                   output / f"shaar-compile-{index}.log", env=env, timeout=1800)
        if not (out / target).is_file():
            raise BuildError(f"Shaar compile output missing: {target}")
    inputs, variables = link_inputs_and_variables(out)
    missing = [name for name in inputs if not (out / name).is_file()]
    if missing:
        raise BuildError("pinned framework link inputs missing: " + ", ".join(missing[:8]))
    for key in ("libs",):
        for token in variables.get(key, "").split():
            if token.endswith((".a", ".rlib")) and not (out / token).is_file():
                raise BuildError(f"GN link library missing: {token}")
    rsp = out / "obj/chrome/chrome_framework_shared_library/Chromium Framework.rsp"
    if rsp.exists() or rsp.is_symlink():
        raise BuildError("unexpected pre-existing framework response file")
    response = inputs + [variables.get(key, "") for key in
                         ("frameworks", "swiftmodules", "solibs", "libs")]
    rsp.write_text(" ".join(part for part in response if part) + "\n")
    link_target = "obj/chrome/chrome_framework_shared_library/Chromium Framework"
    command = ninja_command(ninja, out, link_target)
    if ("../../build/toolchain/apple/linker_driver.py" not in command or
            f'"@{link_target}.rsp"' not in command or
            "-Wl,-exported_symbols_list,../../chrome/browser/shaar/shaar_engine.exports"
            not in command or "-Wl,--thinlto-jobs=all" not in command):
        raise BuildError("unexpected GN framework link command")
    command = command.replace("-Wl,--thinlto-jobs=all", "-Wl,--thinlto-jobs=6", 1)
    try:
        run_logged(["/usr/sbin/taskpolicy", "-b", "/bin/sh", "-c", command], out,
                   output / "relink.log", env=env,
                   timeout=config["build"]["timeoutsSeconds"]["build"])
    finally:
        rsp.unlink(missing_ok=True)
    linked = out / link_target
    binary = output / config["build"]["frameworkBinary"]
    if not linked.is_file() or linked.is_symlink() or binary.is_symlink():
        raise BuildError("GN linked framework binary missing or unsafe")
    shutil.copy2(linked, binary)
    return {"strategy": "validated-reference-objects-relink",
            "gnLinkInputCount": len(inputs), "shaarObjectsCompiled": len(objects),
            "thinLTOJobs": 6}


def run_dual_export(repo: Path, reference: Path, config: dict,
                    relink_only: bool = False) -> dict:
    """Temporary phase-3 development build; the final target keeps its no-Ardia gate."""
    output = guarded_output(repo)
    source, reference_root, reference_record = validate_reference(
        repo, reference, output, config)
    if config["build"]["buildJobs"] != 6:
        raise BuildError("native build must retain the six-job cap")
    free_bytes = shutil.disk_usage(repo).free
    if free_bytes < config["build"]["minimumFreeBytes"]:
        raise BuildError("insufficient free space for source build")
    output = prepare_owned_output(repo)
    receipt = output / RECEIPT_FILE
    record = {"schemaVersion": 1, "sourceKind": "shaar", "mode": "dual-export",
              "buildStrategy": "validated-reference-objects-relink" if relink_only else "full-siso",
              "status": "running", "startedAt": now_utc(), "output": str(output),
              "reference": str(source),
              "referenceReceiptSha256": sha256(reference_root / RECEIPT_FILE),
              "referenceChromeBuildSha256": sha256(source / "chrome/BUILD.gn"),
              "referenceFrameworkSha256": sha256(
                  reference_root / config["build"]["frameworkBinary"]),
              "referenceStatus": reference_record["status"],
              "configSha256": sha256(repo / CONFIG), "layerSha256": config["layer"]["sha256"],
              "stages": {}}
    write_receipt(receipt, record)

    def stage(name: str, action):
        print(f"stage: {name}", flush=True)
        record["stages"][name] = {"status": "running", "startedAt": now_utc()}
        write_receipt(receipt, record)
        result = action()
        record["stages"][name] = {"status": "succeeded", "finishedAt": now_utc()}
        write_receipt(receipt, record)
        return result

    try:
        copied = stage("snapshot", lambda: snapshot_source(
            output, source, reference_root, config, receipt, record))
        stage("layer-and-patch", lambda: install_layer(repo, copied, config))
        env = dict(os.environ)
        env["PATH"] = str(output / "depot_tools") + os.pathsep + env.get("PATH", "")
        env["DEPOT_TOOLS_UPDATE"] = "0"
        env["VPYTHON_VIRTUALENV_ROOT"] = str(output / "vpython-root")
        gn = copied / "buildtools/mac/gn"
        stage("gn", lambda: run_logged(
            ["/usr/sbin/taskpolicy", "-b", str(gn), "gen",
             "out/" + config["build"]["configuration"]], copied, output / "gn.log",
            env=env, timeout=config["build"]["timeoutsSeconds"]["gn"]))
        if relink_only:
            record["relink"] = stage("build", lambda: relink_from_reference_objects(
                output, copied, config, env))
            write_receipt(receipt, record)
        else:
            stage("build", lambda: run_logged(
                ["/usr/sbin/taskpolicy", "-b",
                 str(output / "depot_tools/autoninja"), "-j", "6", "-k", "0", "-C",
                 "out/" + config["build"]["configuration"], "chrome_framework"],
                copied, output / "build.log", env=env,
                timeout=config["build"]["timeoutsSeconds"]["build"]))
        binary = output / config["build"]["frameworkBinary"]
        verified = stage("exports", lambda: verify_framework(
            repo, binary, receipt, config, "dual-export"))
        # verify_framework writes the export receipt, so restore the stage ledger.
        record["framework"] = verified["framework"]
        write_receipt(receipt, record)
        stage("swift-loader", lambda: probe_swift_loader(repo, output, binary))
        record["nativeLoad"] = {"status": "succeeded", "abiMajor": 1,
                                "loader": "Sources/ShaarEngineABI/ShaarEngineABI.swift"}
        if (sha256(reference_root / RECEIPT_FILE) != record["referenceReceiptSha256"] or
                sha256(source / "chrome/BUILD.gn") != record["referenceChromeBuildSha256"] or
                sha256(reference_root / config["build"]["frameworkBinary"]) !=
                record["referenceFrameworkSha256"]):
            raise BuildError("read-only reference changed during Shaar build")
        record["status"] = "succeeded"
        record["finishedAt"] = now_utc()
        write_receipt(receipt, record)
        return record
    except (BuildError, OSError, subprocess.SubprocessError) as exc:
        record["status"] = "failed"
        record["failure"] = str(exc)
        record["finishedAt"] = now_utc()
        write_receipt(receipt, record)
        raise


def probe_swift_loader(repo: Path, output: Path, binary: Path) -> None:
    loader = checked_repo_file(repo, "Sources/ShaarEngineABI/ShaarEngineABI.swift")
    c_header = checked_repo_file(repo, "Sources/ShaarEngineC/include/shaar_engine.h")
    module_map = output / "shaar-loader-probe.modulemap"
    module_map.write_text(
        "module ShaarEngineC {\n"
        f"  umbrella {json.dumps(str(c_header.parent))}\n"
        "  export *\n}\n"
    )
    probe = output / "shaar-loader-probe.swift"
    probe.write_text('''import Foundation
@main struct Probe {
  static func main() throws {
    let framework = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let loader = try ShaarEngineLoader.load(frameworkURL: framework)
    guard loader.currentMajor() == 1 else { fatalError("unexpected Shaar ABI") }
    print("shaar_loader_abi_major=1")
  }
}
''')
    executable = output / "shaar-loader-probe"
    run_logged(["/usr/sbin/taskpolicy", "-b", "/usr/bin/swiftc",
                "-Xcc", f"-fmodule-map-file={module_map}",
                str(loader), str(probe), "-o", str(executable)], output,
               output / "swift-probe-build.log", timeout=300)
    framework = binary.parents[2]
    run_logged(["/usr/sbin/taskpolicy", "-b", str(executable),
                str(framework)], output, output / "swift-probe.log", timeout=120)
    if "shaar_loader_abi_major=1" not in (output / "swift-probe.log").read_text():
        raise BuildError("Swift loader did not report ABI major 1")


def save_receipt(receipt: Path, record: dict) -> None:
    temporary = receipt.with_name(receipt.name + ".tmp")
    if temporary.exists() or temporary.is_symlink() or receipt.is_symlink():
        raise BuildError("unsafe receipt path")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(record, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, receipt)
        os.chmod(receipt, 0o600)
    finally:
        temporary.unlink(missing_ok=True)


def reject_symlink_components(root: Path, path: Path) -> None:
    try:
        relative = path.relative_to(root)
    except ValueError as exc:
        raise BuildError("Shaar layer test path escaped output") from exc
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise BuildError(f"symlink rejected in Shaar test path: {current}")


def run_layer_tests(repo: Path, config: dict, runner=subprocess.run) -> dict:
    """Build and run the aggregate layer test target in an existing owned output."""
    output = guarded_output(repo)
    if not output.is_dir() or output.is_symlink():
        raise BuildError("Shaar output does not exist")
    if output.stat().st_uid != os.getuid() or stat.S_IMODE(output.stat().st_mode) & 0o077:
        raise BuildError("Shaar output ownership or mode rejected")
    owner = output / OWNER_FILE
    if owner.is_symlink() or not owner.is_file() or json.loads(owner.read_text()) != owner_record(repo):
        raise BuildError("Shaar output owner record mismatch")

    receipt = output / RECEIPT_FILE
    if receipt.is_symlink() or not receipt.is_file():
        raise BuildError("Shaar build receipt is missing or unsafe")
    record = json.loads(receipt.read_text())
    if (record.get("sourceKind") != "shaar" or record.get("output") != str(output) or
            record.get("configSha256") != sha256(repo / CONFIG) or
            record.get("layerSha256") != config["layer"]["sha256"]):
        raise BuildError("Shaar build receipt does not match the current source inputs")

    chromium = output / "chromium_git/chromium/src"
    build_dir = chromium / "out" / config["build"]["configuration"]
    gn = output / "depot_tools/gn"
    siso = output / "depot_tools/siso"
    args_file = build_dir / "args.gn"
    executable = build_dir / config["build"].get("layerTestBinary", "shaar_layer_unittests")
    for path in (chromium, build_dir, gn, siso, args_file):
        reject_symlink_components(output, path)
    if (not chromium.is_dir() or not build_dir.is_dir() or not gn.is_file() or
            not siso.is_file() or not args_file.is_file()):
        raise BuildError("existing Shaar Chromium output is incomplete")

    target = config["build"].get("layerTestLabel", "//chrome:shaar_layer_unittests")
    build_command = [str(siso), "ninja", "--offline", "-C", str(build_dir),
                     "-local_jobs", str(config["build"]["buildJobs"]), target]
    stage = {
        "status": "running",
        "startedAt": datetime.now(timezone.utc).isoformat(),
        "target": target,
        "buildCommand": build_command,
    }
    record.setdefault("stages", {})["layer-tests"] = stage
    save_receipt(receipt, record)
    try:
        args_text = args_file.read_text()
        if "shaar_layer_tests = true" not in args_text.splitlines():
            args_text = "\n".join(line for line in args_text.splitlines()
                                  if not line.strip().startswith("shaar_layer_tests ="))
            args_file.write_text(args_text.rstrip() + "\nshaar_layer_tests = true\n")
            gn_result = runner(
                [str(gn), "gen", str(build_dir)], cwd=chromium, check=False,
                capture_output=True, text=True,
                timeout=config["build"]["timeoutsSeconds"]["gn"])
            stage["gnExitCode"] = gn_result.returncode
            if gn_result.returncode != 0:
                raise BuildError(f"layer test GN generation failed with {gn_result.returncode}")
        build_result = runner(
            build_command, cwd=chromium, check=False, capture_output=True, text=True,
            timeout=config["build"]["timeoutsSeconds"]["build"])
        stage["buildExitCode"] = build_result.returncode
        if build_result.returncode != 0:
            raise BuildError(f"layer test target build failed with {build_result.returncode}")
        if executable.is_symlink() or not executable.is_file():
            raise BuildError("layer test executable was not produced")

        with tempfile.TemporaryDirectory(prefix="shaar-layer-tests-", dir=output) as temp_dir:
            result_path = Path(temp_dir) / "gtest-results.json"
            test_command = [str(executable), "--headless",
                            f"--gtest_output=json:{result_path}"]
            stage["testCommand"] = test_command
            result = runner(
                test_command, cwd=build_dir, check=False, capture_output=True, text=True,
                timeout=config["build"]["timeoutsSeconds"].get("layerTests", 1800))
            stage["testExitCode"] = result.returncode
            if not result_path.is_file() or result_path.is_symlink():
                raise BuildError("layer test did not write its gtest JSON report")
            stage["result"] = json.loads(result_path.read_text())
        if stage["testExitCode"] != 0:
            raise BuildError(f"layer tests failed with {stage['testExitCode']}")
        stage["status"] = "succeeded"
        stage["finishedAt"] = datetime.now(timezone.utc).isoformat()
        save_receipt(receipt, record)
        return stage
    except (BuildError, OSError, ValueError, subprocess.SubprocessError) as exc:
        stage["status"] = "failed"
        stage["failure"] = str(exc)
        stage["finishedAt"] = datetime.now(timezone.utc).isoformat()
        save_receipt(receipt, record)
        raise


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="run a temporary dual-export source build")
    parser.add_argument("--layer-tests", action="store_true",
                        help="build and run the aggregate layer tests in an existing source output")
    parser.add_argument("--reference-source", type=Path, metavar="CHROMIUM_SRC",
                        help="read-only pinned source checkout to copy-on-write snapshot")
    parser.add_argument("--relink-from-reference", action="store_true",
                        help="reuse verified pinned objects and relink only the Shaar layer")
    parser.add_argument("--verify-framework", type=Path, metavar="BINARY")
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--verify-mode", choices=("final", "dual-export"),
                        default="final", help="expected framework export mode")
    options = parser.parse_args(argv)
    repo = Path(__file__).resolve().parents[1]
    try:
        if options.layer_tests:
            if options.run or options.reference_source or options.relink_from_reference or options.verify_framework or options.receipt:
                raise BuildError("--layer-tests cannot be combined with build or verification flags")
            config = load_config(repo)
            print(json.dumps(run_layer_tests(repo, config), indent=2))
            return 0
        config = load_config(repo)
        if options.run:
            if not options.reference_source or options.verify_framework or options.receipt:
                raise BuildError("--run requires only --reference-source")
            print(json.dumps(run_dual_export(repo, options.reference_source, config,
                                             options.relink_from_reference), indent=2))
        elif options.reference_source or options.relink_from_reference:
            raise BuildError("--reference-source and --relink-from-reference require --run")
        elif options.verify_framework:
            if not options.receipt:
                raise BuildError("--verify-framework requires --receipt")
            binary = Path(os.path.abspath(options.verify_framework))
            receipt = Path(os.path.abspath(options.receipt))
            print(json.dumps(verify_framework(repo, binary, receipt, config,
                                              options.verify_mode), indent=2))
        elif options.receipt:
            raise BuildError("--receipt requires --verify-framework")
        else:
            print(json.dumps(dry_run(repo, config), indent=2))
        return 0
    except (BuildError, OSError, ValueError, KeyError, json.JSONDecodeError,
            subprocess.SubprocessError) as exc:
        print(f"build-shaar-engine-source: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
