#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Rebuild the pinned Chromium 157 Shaar source tree from clean inputs.

Usage:
  python3 scripts/build-chromium-157-source.py /path/to/fresh/build-root

The script creates Chromium, ungoogled-chromium, and ungoogled-macos checkouts
under the supplied root, applies the pinned upstream stack and Shaar overlay,
records an application receipt, generates Release_GN_arm64, builds the
framework and layer tests through shaar-heavy, and runs the layer tests.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


REPO = Path(__file__).resolve().parents[1]
SPEC_PATH = REPO / "ThirdParty/ChromiumEngine/source-build.json"
SPEC = json.loads(SPEC_PATH.read_text())
MINIMUM_FREE_BYTES = 25 * 1024**3
GN_ARGS = """chrome_pgo_phase = 0
clang_use_chrome_plugins = false
disable_fieldtrial_testing_config = true
enable_hangout_services_extension = false
enable_mdns = false
enable_remoting = false
enable_reporting = false
enable_service_discovery = false
enable_widevine = true
exclude_unwind_tables = true
google_api_key = \"\"
google_default_client_id = \"\"
google_default_client_secret = \"\"
safe_browsing_mode = 0
treat_warnings_as_errors = false
use_official_google_api_keys = false
use_unofficial_version_number = false
v8_drumbrake_bounds_checks = true
is_debug = false
is_official_build = true
is_component_build = false
proprietary_codecs = true
ffmpeg_branding = \"Chrome\"
use_sysroot = false
enable_rust = true
fatal_linker_warnings = false
enable_updater = false
symbol_level = 0
blink_symbol_level = 0
concurrent_links = 1
use_thin_lto = false
target_cpu = \"arm64\"
use_remoteexec = false

enable_browser_tests = false
"""


def run(command: list[str], cwd: Path, env: dict[str, str] | None = None) -> None:
    print("+ " + " ".join(command), flush=True)
    subprocess.run(command, cwd=cwd, env=env, check=True)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_manifest_hashes() -> None:
    for entry in SPEC["patches"]:
        patch_path = REPO / entry["file"]
        actual = sha256(patch_path)
        if actual != entry["sha256"]:
            raise RuntimeError(
                f"patches digest mismatch for {entry['file']}: {actual} != {entry['sha256']}"
            )
    for relative, expected in SPEC["layer"]["files"].items():
        actual = sha256(REPO / "ThirdParty/ChromiumEngine/layer" / relative)
        if actual != expected:
            raise RuntimeError(f"Layer digest mismatch for {relative}: {actual} != {expected}")


def check_free_space(path: Path) -> None:
    available = shutil.disk_usage(path).free
    if available < MINIMUM_FREE_BYTES:
        raise RuntimeError(
            f"Need at least 25 GiB free before source/build stages; found {available / 1024**3:.1f} GiB"
        )
    print(f"Free space: {available / 1024**3:.1f} GiB", flush=True)


def clone_at(repository: str, commit: str, destination: Path,
             reference: Path | None = None) -> None:
    if destination.exists():
        raise RuntimeError(f"Refusing to reuse existing checkout: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    command = ["git", "clone", "--no-checkout"]
    if reference:
        command.extend(["--reference-if-able", str(reference)])
    command.extend([repository, str(destination)])
    run(command, cwd=destination.parent)
    run(["git", "checkout", "--detach", commit], cwd=destination)
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=destination, text=True).strip()
    if actual != commit:
        raise RuntimeError(f"Checkout mismatch at {destination}: {actual} != {commit}")


def checkout_chromium(repository: str, commit: str, destination: Path,
                      reference: Path | None) -> None:
    if reference is None:
        clone_at(repository, commit, destination)
        return
    if destination.exists():
        raise RuntimeError(f"Refusing to reuse existing checkout: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    run(["git", "init", str(destination)], cwd=destination.parent)
    object_store = reference / ".git/objects"
    if not object_store.is_dir():
        raise RuntimeError(f"Chromium object reference has no object store: {object_store}")
    alternate_file = destination / ".git/objects/info/alternates"
    alternate_file.parent.mkdir(parents=True, exist_ok=True)
    alternate_file.write_text(str(object_store.resolve()) + "\n")
    run(["git", "remote", "add", "origin", repository], cwd=destination)
    run(["git", "cat-file", "-e", f"{commit}^{{commit}}"], cwd=destination)
    run(["git", "checkout", "--detach", commit], cwd=destination)
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=destination, text=True).strip()
    if actual != commit:
        raise RuntimeError(f"Fresh Chromium checkout mismatch: {actual} != {commit}")
    if subprocess.check_output(["git", "status", "--porcelain"], cwd=destination, text=True).strip():
        raise RuntimeError("Fresh Chromium checkout is unexpectedly dirty")


def write_gclient(chromium_parent: Path) -> None:
    chromium = SPEC["chromium"]
    solutions = [{
            "name": "src",
            "url": f"{chromium['repository']}@{chromium['commit']}",
            "managed": False,
            "custom_deps": {},
            "custom_vars": {"checkout_configuration": "small"},
        }]
    contents = "solutions = " + repr(solutions) + "\ntarget_os = ['mac']\n"
    (chromium_parent / ".gclient").write_text(contents)


def read_series(directory: Path) -> list[Path]:
    series = directory / "series"
    if not series.is_file():
        raise RuntimeError(f"Missing upstream patch series: {series}")
    patches: list[Path] = []
    for raw in series.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        patch_path = (directory / line).resolve()
        if not patch_path.is_file():
            raise RuntimeError(f"Series entry is missing: {patch_path}")
        patches.append(patch_path)
    return patches


def copy_layer(source: Path) -> None:
    layer_root = REPO / "ThirdParty/ChromiumEngine/layer"
    destination = source / "chrome/browser/shaar"
    if destination.exists():
        raise RuntimeError(f"Shaar layer destination already exists: {destination}")
    for relative in SPEC["layer"]["files"]:
        target = source / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(layer_root / relative, target)


def ordered_shaar_patches() -> list[dict[str, str]]:
    return SPEC["patches"]


def pre_shaar_files(source: Path) -> dict[str, dict[str, Any]]:
    paths = sorted({relative for entry in ordered_shaar_patches()
                    for relative in patch_touched_paths(REPO / entry["file"])})
    files: dict[str, dict[str, Any]] = {}
    for relative in paths:
        path = source / relative
        if path.is_symlink():
            files[relative] = {"kind": "symlink", "target": os.readlink(path)}
        elif path.is_file():
            files[relative] = {"kind": "file", "sha256": sha256(path),
                               "executable": bool(path.stat().st_mode & stat.S_IXUSR)}
        elif not path.exists():
            files[relative] = {"kind": "missing"}
        else:
            raise RuntimeError(f"Patch baseline is not a file: {relative}")
    return files


def apply_shaar_patches(source: Path, root: Path, receipt: dict[str, Any]) -> None:
    applied: list[dict[str, str]] = []
    receipt["sourceBuildManifestSha256"] = sha256(SPEC_PATH)
    receipt["layerSha256"] = SPEC["layer"]["sha256"]
    receipt["preShaarFiles"] = pre_shaar_files(source)
    receipt["shaarPatches"] = applied
    write_receipt(root, receipt)
    for index, entry in enumerate(ordered_shaar_patches(), start=1):
        patch_path = REPO / entry["file"]
        expected = entry["sha256"]
        actual = sha256(patch_path)
        if actual != expected:
            raise RuntimeError(f"Patch changed during build: {patch_path}")
        check = subprocess.run(
            ["git", "apply", "--check", "--whitespace=nowarn", str(patch_path)],
            cwd=source, capture_output=True, text=True,
        )
        if check.returncode:
            receipt["failedShaarPatch"] = {
                "file": entry["file"],
                "sha256": actual,
                "error": (check.stdout + check.stderr).strip(),
            }
            write_receipt(root, receipt)
            raise RuntimeError(
                f"Patch {index}/{len(ordered_shaar_patches())} does not apply forward: "
                f"{patch_path.name}\n{check.stdout}{check.stderr}"
            )
        run(["git", "apply", "--whitespace=nowarn", str(patch_path)], cwd=source)
        applied.append({"file": entry["file"], "sha256": actual})
        receipt["shaarPatches"] = list(applied)
        write_receipt(root, receipt)
        print(f"Applied Shaar patch {index}: {patch_path.name}", flush=True)


def write_receipt(root: Path, receipt: dict[str, Any]) -> None:
    (root / "applied-patches.json").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")


def patch_touched_paths(patch_path: Path) -> list[str]:
    paths: list[str] = []
    for line in patch_path.read_text(errors="replace").splitlines():
        if not (line.startswith("--- ") or line.startswith("+++ ")):
            continue
        raw = line[4:].split("\t", 1)[0].split(" ", 1)[0]
        if raw == "/dev/null":
            continue
        if raw.startswith(("a/", "b/")):
            raw = raw[2:]
        if raw not in paths:
            paths.append(raw)
    if not paths:
        raise RuntimeError(f"Could not identify paths touched by patch: {patch_path}")
    return paths


def port_reference_baseline(reference_source: Path, relative: str, target: Path,
                            source_parent: Path) -> dict[str, Any]:
    reference = reference_source / relative
    if not reference.is_file():
        target.unlink(missing_ok=True)
        return {"path": relative, "status": "reference-absent"}

    reversed_patches: list[str] = []
    with tempfile.TemporaryDirectory(prefix="shaar-reference-baseline-",
                                     dir=source_parent) as temporary:
        scratch = Path(temporary)
        baseline_file = scratch / relative
        baseline_file.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(reference, baseline_file)
        for entry in reversed(ordered_shaar_patches()):
            patch_path = REPO / entry["file"]
            if relative not in patch_touched_paths(patch_path):
                continue
            command = ["git", "apply", "--reverse", "--check", "--include", relative,
                       str(patch_path)]
            check = subprocess.run(command, cwd=scratch, capture_output=True, text=True)
            if check.returncode:
                continue
            run(["git", "apply", "--reverse", "--include", relative, str(patch_path)],
                cwd=scratch)
            reversed_patches.append(entry["file"])
        target.parent.mkdir(parents=True, exist_ok=True)
        if baseline_file.exists():
            shutil.copy2(baseline_file, target)
        else:
            target.unlink(missing_ok=True)
            return {"path": relative, "status": "removed-by-shaar-reversal",
                    "reversedShaarPatches": reversed_patches}
        return {"path": relative,
                "status": "ported-reference-baseline",
                "referenceSha256": sha256(reference),
                "baselineSha256": sha256(target),
                "reversedShaarPatches": reversed_patches}


def apply_upstream_patch(patch_path: Path, source: Path, label: str,
                         reference_source: Path | None) -> dict[str, Any]:
    command = ["/usr/bin/patch", "-p1", "--ignore-whitespace", "-i", str(patch_path),
               "-d", str(source), "--no-backup-if-mismatch"]
    dry_run = subprocess.run(command + ["--dry-run"], capture_output=True, text=True)
    digest = sha256(patch_path)
    if dry_run.returncode == 0:
        run(command + ["--forward"], cwd=source)
        return {"series": label, "file": patch_path.name, "sha256": digest,
                "status": "applied"}

    if reference_source is None:
        raise RuntimeError(
            f"Upstream patch does not apply and no reference tree was provided: "
            f"{patch_path.name}\n{dry_run.stdout}{dry_run.stderr}"
        )

    reconciled: list[dict[str, str]] = []
    for relative in patch_touched_paths(patch_path):
        target = source / relative
        reference = reference_source / relative
        before = sha256(target) if target.is_file() else "absent"
        reference_digest = sha256(reference) if reference.is_file() else "absent"
        if before != reference_digest:
            reconciled.append(port_reference_baseline(reference_source, relative, target,
                                                       source.parent))
        else:
            reconciled.append({"path": relative, "status": "matches-reference",
                               "referenceSha256": reference_digest})
    copied = any(item["status"] == "ported-reference-baseline" for item in reconciled)
    status = "ported-from-reference" if copied else "skipped-matches-reference"
    return {"series": label, "file": patch_path.name, "sha256": digest,
            "status": status, "reason": "Patch dry-run failed; compared each touched file "
            "with the reference tree and removed matching Shaar patch hunks before porting.",
            "patchError": (dry_run.stdout + dry_run.stderr).strip(),
            "files": reconciled}


def apply_upstream_stack(source: Path, root: Path, receipt: dict[str, Any],
                         reference_source: Path | None) -> None:
    ungoogled = root / "ungoogled-chromium"
    macos = root / "ungoogled-chromium-macos"
    main_patches = ungoogled / "patches"
    platform_patches = macos / "patches"

    # This is a gclient source checkout, not an ungoogled release tarball.
    # The generic pruning.list includes paths absent from Chromium 157's
    # macOS-targeted DEPS checkout, so pruning is intentionally not run here.
    # Apply both upstream series in build.sh order, then substitute domains.
    receipt["upstreamPruning"] = {
        "performed": False,
        "reason": "The generic pruning.list includes 123 files absent from the pinned macOS gclient checkout.",
    }
    write_receipt(root, receipt)
    upstream_entries: list[dict[str, Any]] = []
    for index, patch_path in enumerate(read_series(main_patches), start=1):
        entry = apply_upstream_patch(patch_path, source, "ungoogled-core", reference_source)
        entry["file"] = patch_path.relative_to(main_patches).as_posix()
        upstream_entries.append(entry)
        receipt["upstreamPatchSeries"] = list(upstream_entries)
        write_receipt(root, receipt)
        print(f"Applied ungoogled-core patch {index}: {patch_path.name}", flush=True)
    apply_macos_series(source, root, receipt, reference_source, platform_patches,
                       upstream_entries)
    apply_domain_substitutions(source, root, receipt)


def apply_macos_series(source: Path, root: Path, receipt: dict[str, Any],
                       reference_source: Path | None, directory: Path | None = None,
                       upstream_entries: list[dict[str, Any]] | None = None) -> None:
    if directory is None:
        directory = root / "ungoogled-chromium-macos/patches"
    entries = list(upstream_entries or receipt.get("upstreamPatchSeries", []))
    for index, patch_path in enumerate(read_series(directory), start=1):
        entry = apply_upstream_patch(patch_path, source, "ungoogled-macos", reference_source)
        entry["file"] = patch_path.relative_to(directory).as_posix()
        entries.append(entry)
        receipt["upstreamPatchSeries"] = list(entries)
        write_receipt(root, receipt)
        state = entry["status"]
        print(f"Processed ungoogled-macos patch {index} ({state}): {patch_path.name}", flush=True)
def apply_domain_substitutions(source: Path, root: Path, receipt: dict[str, Any]) -> None:
    ungoogled = root / "ungoogled-chromium"
    run([sys.executable, str(ungoogled / "utils/domain_substitution.py"), "apply",
         "-r", str(ungoogled / "domain_regex.list"), "-f",
         str(ungoogled / "domain_substitution.list"), str(source)], cwd=source)
    receipt["upstreamTransformFiles"] = [
        {"file": str(ungoogled / "domain_regex.list"),
         "sha256": sha256(ungoogled / "domain_regex.list")},
        {"file": str(ungoogled / "domain_substitution.list"),
         "sha256": sha256(ungoogled / "domain_substitution.list")},
    ]
    write_receipt(root, receipt)


def shaar_heavy() -> Path:
    executable = Path.home() / "bin/shaar-heavy"
    if not executable.is_file():
        raise RuntimeError(f"Missing shared build-slot wrapper: {executable}")
    return executable


def build_and_test(source: Path, root: Path) -> None:
    check_free_space(root)
    output = source / "out/Release_GN_arm64"
    output.mkdir(parents=True, exist_ok=True)
    (output / "args.gn").write_text(GN_ARGS)
    gn = source / "buildtools/mac/gn"
    ninja = source / "third_party/ninja/ninja"
    if not gn.exists() or not ninja.exists():
        raise RuntimeError("GN or Ninja missing after gclient sync")
    wrapper = str(shaar_heavy())
    run([wrapper, str(gn), "gen", str(output)], cwd=source)
    run([wrapper, str(ninja), "-C", str(output), "-j", "10",
         "chrome_framework", "shaar_layer_unittests"], cwd=source)
    run([wrapper, str(output / "shaar_layer_unittests")], cwd=source)


def resume_after_sync(root: Path, build: bool, reference_source: Path | None) -> None:
    chromium_parent = root / "chromium_git/chromium"
    source = chromium_parent / "src"
    chromium = SPEC["chromium"]
    expected = chromium["commit"]
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source,
                                     text=True).strip()
    if actual != expected:
        raise RuntimeError(f"Chromium revision mismatch: {actual} != {expected}")
    if subprocess.check_output(["git", "status", "--porcelain"], cwd=source,
                               text=True).strip():
        raise RuntimeError("Synced Chromium source is not clean; refusing to resume")
    for checkout, commit in (
        (root / "ungoogled-chromium", SPEC["ungoogled"]["commit"]),
        (root / "ungoogled-chromium-macos", SPEC["ungoogled"]["macosCommit"]),
        (root / "depot_tools", SPEC["depotTools"]["commit"]),
    ):
        actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=checkout,
                                         text=True).strip()
        if actual != commit:
            raise RuntimeError(f"Pinned checkout mismatch at {checkout}: {actual} != {commit}")
    receipt: dict[str, Any] = {
        "schemaVersion": 1,
        "chromium": {"repository": chromium["repository"], "commit": expected},
        "ungoogled": {"commit": SPEC["ungoogled"]["commit"],
                      "macosCommit": SPEC["ungoogled"]["macosCommit"]},
        "depotTools": {"commit": SPEC["depotTools"]["commit"]},
        "sourceBuildManifestSha256": sha256(SPEC_PATH),
        "layerSha256": SPEC["layer"]["sha256"],
        "chromiumObjectReference": str(root / "chromium_git/chromium/src" / ".git/objects/info/alternates"),
    }
    write_receipt(root, receipt)
    receipt["referenceSourceTree"] = str(reference_source) if reference_source else None
    apply_upstream_stack(source, root, receipt, reference_source)
    copy_layer(source)
    stage_script = REPO / SPEC["devtoolsFrontend157"]["stageScript"]
    frontend_destination = source / "third_party/devtools-frontend/src/front_end/panels/shaar"
    run([sys.executable, str(stage_script), "--destination", str(frontend_destination)], cwd=REPO)
    apply_shaar_patches(source, root, receipt)
    print(f"Patch receipt: {root / 'applied-patches.json'}", flush=True)
    if build:
        build_and_test(source, root)


def resume_after_core(root: Path, reference_source: Path) -> None:
    chromium = SPEC["chromium"]
    source = root / "chromium_git/chromium/src"
    receipt_path = root / "applied-patches.json"
    if not receipt_path.is_file():
        raise RuntimeError(f"Missing upstream-core receipt: {receipt_path}")
    receipt = json.loads(receipt_path.read_text())
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source,
                                     text=True).strip()
    if actual != chromium["commit"]:
        raise RuntimeError(f"Chromium revision mismatch: {actual} != {chromium['commit']}")
    core_directory = root / "ungoogled-chromium/patches"
    expected = read_series(core_directory)
    recorded = receipt.get("upstreamPatchSeries", [])
    if len(recorded) != len(expected):
        raise RuntimeError(f"Expected {len(expected)} recorded core patches, found {len(recorded)}")
    for patch_path, entry in zip(expected, recorded):
        if (entry.get("series") != "ungoogled-core"
                or entry.get("file") != patch_path.relative_to(core_directory).as_posix()
                or entry.get("sha256") != sha256(patch_path)):
            raise RuntimeError(f"Core patch receipt mismatch at {patch_path.name}")
    receipt["referenceSourceTree"] = str(reference_source)
    apply_macos_series(source, root, receipt, reference_source)
    apply_domain_substitutions(source, root, receipt)
    copy_layer(source)
    stage_script = REPO / SPEC["devtoolsFrontend157"]["stageScript"]
    frontend_destination = source / "third_party/devtools-frontend/src/front_end/panels/shaar"
    run([sys.executable, str(stage_script), "--destination", str(frontend_destination)], cwd=REPO)
    apply_shaar_patches(source, root, receipt)
    print(f"Patch receipt: {receipt_path}", flush=True)
    build_and_test(source, root)


def resume_after_upstream(root: Path, reference_source: Path) -> None:
    source = root / "chromium_git/chromium/src"
    receipt_path = root / "applied-patches.json"
    receipt = json.loads(receipt_path.read_text())
    macos_entries = [entry for entry in receipt.get("upstreamPatchSeries", [])
                     if entry.get("series") == "ungoogled-macos"]
    expected_macos = read_series(root / "ungoogled-chromium-macos/patches")
    if len(macos_entries) != len(expected_macos):
        raise RuntimeError(f"Expected {len(expected_macos)} macOS patch records, found {len(macos_entries)}")
    for patch_path, entry in zip(expected_macos, macos_entries):
        if (entry.get("file") != patch_path.relative_to(root / "ungoogled-chromium-macos/patches").as_posix()
                or entry.get("sha256") != sha256(patch_path)):
            raise RuntimeError(f"macOS patch receipt mismatch at {patch_path.name}")
        for file_entry in entry.get("files", []):
            if file_entry.get("status") != "copied-reference":
                continue
            relative = file_entry["path"]
            normalized = port_reference_baseline(reference_source, relative,
                                                  source / relative, source.parent)
            file_entry.update(normalized)
    receipt["referenceSourceTree"] = str(reference_source)
    write_receipt(root, receipt)
    apply_domain_substitutions(source, root, receipt)

    if not (source / "chrome/browser/shaar").is_dir():
        copy_layer(source)
    stage_script = REPO / SPEC["devtoolsFrontend157"]["stageScript"]
    frontend_destination = source / "third_party/devtools-frontend/src/front_end/panels/shaar"
    if not frontend_destination.is_dir():
        run([sys.executable, str(stage_script), "--destination", str(frontend_destination)], cwd=REPO)
    apply_shaar_patches(source, root, receipt)
    print(f"Patch receipt: {receipt_path}", flush=True)
    build_and_test(source, root)


def prepare(root: Path, build: bool, chromium_reference: Path | None,
            reference_source: Path | None) -> None:
    if root.exists() and any(root.iterdir()):
        raise RuntimeError(f"Fresh build root must be empty: {root}")
    root.mkdir(parents=True, exist_ok=True)
    check_free_space(root)
    verify_manifest_hashes()

    chromium_parent = root / "chromium_git/chromium"
    source = chromium_parent / "src"
    chromium = SPEC["chromium"]
    checkout_chromium(chromium["repository"], chromium["commit"], source,
                      reference=chromium_reference)
    write_gclient(chromium_parent)

    ungoogled = SPEC["ungoogled"]
    clone_at(ungoogled["repository"], ungoogled["commit"], root / "ungoogled-chromium")
    clone_at(ungoogled["macosRepository"], ungoogled["macosCommit"],
             root / "ungoogled-chromium-macos")
    depot = SPEC["depotTools"]
    clone_at(depot["repository"], depot["commit"], root / "depot_tools")

    env = os.environ.copy()
    env["PATH"] = f"{root / 'depot_tools'}:{env.get('PATH', '')}"
    run([str(root / "depot_tools/gclient"), "sync", "--no-history", "-j", "4"],
        cwd=chromium_parent, env=env)
    run(["git", "checkout", "--detach", depot["commit"]], cwd=root / "depot_tools")
    actual_chromium = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source,
                                              text=True).strip()
    if actual_chromium != chromium["commit"]:
        raise RuntimeError(f"Chromium revision drift after sync: {actual_chromium}")

    receipt: dict[str, Any] = {
        "schemaVersion": 1,
        "chromium": {"repository": chromium["repository"], "commit": actual_chromium},
        "ungoogled": {"commit": ungoogled["commit"], "macosCommit": ungoogled["macosCommit"]},
        "depotTools": {"commit": depot["commit"]},
        "sourceBuildManifestSha256": sha256(SPEC_PATH),
        "layerSha256": SPEC["layer"]["sha256"],
        "chromiumObjectReference": str(chromium_reference) if chromium_reference else None,
    }
    write_receipt(root, receipt)
    receipt["referenceSourceTree"] = str(reference_source) if reference_source else None
    apply_upstream_stack(source, root, receipt, reference_source)
    copy_layer(source)

    stage_script = REPO / SPEC["devtoolsFrontend157"]["stageScript"]
    frontend_destination = source / "third_party/devtools-frontend/src/front_end/panels/shaar"
    run([sys.executable, str(stage_script), "--destination", str(frontend_destination)], cwd=REPO)
    apply_shaar_patches(source, root, receipt)

    receipt_path = root / "applied-patches.json"
    print(f"Patch receipt: {receipt_path}", flush=True)
    if build:
        build_and_test(source, root)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build_root", type=Path)
    parser.add_argument("--chromium-reference", type=Path,
                        help="optional local object reference; checkout files remain fresh")
    parser.add_argument("--prepare-only", action="store_true",
                        help="stop after clean sync, patch application, and receipt")
    parser.add_argument("--resume-after-sync", action="store_true",
                        help="resume in an existing fresh root after successful gclient sync")
    parser.add_argument("--resume-after-core", action="store_true",
                        help="resume an existing fresh root after all core patches are recorded")
    parser.add_argument("--resume-after-upstream", action="store_true",
                        help="resume after upstream patches, normalize reference ports, and apply Shaar")
    parser.add_argument("--reference-tree", type=Path,
                        default=Path("/Users/david/shaar-engine/chromium_git/chromium/src"),
                        help="source tree whose touched-file state resolves upstream patch mismatches")
    args = parser.parse_args()
    try:
        reference_source = args.reference_tree.expanduser().resolve()
        if args.resume_after_core:
            if args.chromium_reference or args.prepare_only or args.resume_after_sync or args.resume_after_upstream:
                raise RuntimeError("--resume-after-core cannot be combined with other mode options")
            resume_after_core(args.build_root.expanduser().resolve(), reference_source)
            return 0
        if args.resume_after_upstream:
            if args.chromium_reference or args.prepare_only or args.resume_after_sync or args.resume_after_core:
                raise RuntimeError("--resume-after-upstream cannot be combined with other mode options")
            resume_after_upstream(args.build_root.expanduser().resolve(), reference_source)
            return 0
        if args.resume_after_sync:
            if args.chromium_reference or args.prepare_only:
                raise RuntimeError("--resume-after-sync cannot be combined with other mode options")
            resume_after_sync(args.build_root.expanduser().resolve(), build=True,
                              reference_source=reference_source)
            return 0
        if args.chromium_reference:
            source_ref = args.chromium_reference.expanduser().resolve()
            actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source_ref,
                                              text=True).strip()
            if actual != SPEC["chromium"]["commit"]:
                raise RuntimeError(f"Chromium object reference is not the pinned revision: {actual}")
        reference = args.chromium_reference.expanduser().resolve() if args.chromium_reference else None
        prepare(args.build_root.expanduser().resolve(), build=not args.prepare_only,
                chromium_reference=reference, reference_source=reference_source)
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
