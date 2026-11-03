#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Validate the Shaar Chromium source inputs and plan the separate build.

Step 0 deliberately has no execution mode. Source sync, patching, GN generation,
and engine compilation become executable only after their Shaar-owned stages are
implemented and reviewed. A dry run performs no filesystem writes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys


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
    "chrome/browser/shaar/engine/shaar_engine.cc",
    "chrome/browser/shaar/engine/shaar_event_bridge.h",
    "chrome/browser/shaar/profiles/shaar_profiles.cc",
    "chrome/browser/shaar/profiles/shaar_profiles.h",
    "chrome/browser/shaar/profiles/shaar_profiles_unittest.cc",
    "chrome/browser/shaar/public/shaar_engine.h",
    "chrome/browser/shaar/shaar_engine.exports",
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


def owner_record(repo: Path) -> dict:
    repo = repo.resolve(strict=True)
    return {"schemaVersion": 1, "sourceKind": "shaar", "uid": os.getuid(),
            "repo": str(repo), "output": str(repo / OUTPUT)}


def prepare_owned_output(repo: Path) -> Path:
    """Reserved for the future build runner; never called by the dry run."""
    output = guarded_output(repo)
    expected = owner_record(repo)
    if output.exists():
        if output.stat().st_uid != os.getuid() or stat.S_IMODE(output.stat().st_mode) & 0o077:
            raise BuildError("Shaar output ownership or mode rejected")
        owner = output / OWNER_FILE
        if owner.is_symlink() or not owner.is_file() or json.loads(owner.read_text()) != expected:
            raise BuildError("Shaar output owner record mismatch")
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
        "Chromium Framework.framework/Versions/A/Chromium Framework"
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
    header = checked_repo_file(repo, "Design/shaar_engine.h")
    if sha256(header) != actual_files.get("chrome/browser/shaar/public/shaar_engine.h"):
        raise BuildError("installed ABI header differs from reviewed draft")
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
    guarded_output(repo)
    return config


def dry_run(repo: Path, config: dict) -> dict:
    return {
        "sourceKind": "shaar",
        "execution": "step-0 dry-run only; no source sync or build",
        "output": str(guarded_output(repo)),
        "configuration": config["build"]["configuration"],
        "target": config["build"]["target"],
        "chromiumCommit": config["chromium"]["commit"],
        "layerSha256": config["layer"]["sha256"],
        "patches": [patch["file"] for patch in config["patches"]],
        "stages": [
            "pinned Chromium and tool sync",
            "ungoogled patch and domain stages",
            "ordered Shaar patches",
            "verified Shaar layer installation at chrome/browser/shaar",
            "GN generation for chrome_framework",
            "framework build and export receipt verification",
        ],
        "requiredExports": config["requiredExports"],
        "forbiddenExports": ["ac_*", "ArdiaCore*"],
    }


def check_exports(symbols: str, all_symbols: str | None = None) -> dict:
    """Validate external exports and all named symbols in the final binary."""
    found = set(symbols.splitlines())
    missing = sorted(set(REQUIRED_EXPORTS) - found)
    all_names = {line.split()[-1] for line in (all_symbols or symbols).splitlines() if line.split()}
    forbidden = sorted(name for name in (found | all_names)
                       if name.startswith(("_ac_", "ac_")) or "ArdiaCore" in name)
    if missing:
        raise BuildError("missing Shaar framework exports: " + ", ".join(missing))
    if forbidden:
        raise BuildError("legacy framework exports present: " + ", ".join(forbidden))
    return {"required": list(REQUIRED_EXPORTS), "forbiddenFound": [],
            "exportedSymbolCount": len(found), "allSymbolCount": len(all_names)}


def verify_framework(repo: Path, binary: Path, receipt: Path, config: dict) -> dict:
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
    exports = check_exports(exported.stdout, all_symbols.stdout)
    record = {
        "schemaVersion": 1,
        "sourceKind": "shaar",
        "output": str(output),
        "configSha256": sha256(repo / CONFIG),
        "layerSha256": config["layer"]["sha256"],
        "framework": {
            "binary": str(binary.relative_to(output)),
            "sha256": sha256(binary),
            "exports": exports,
        },
    }
    if not receipt.parent.is_dir():
        raise BuildError("receipt parent missing")
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
    return record


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="reserved until Shaar source stages are reviewed")
    parser.add_argument("--verify-framework", type=Path, metavar="BINARY")
    parser.add_argument("--receipt", type=Path)
    options = parser.parse_args(argv)
    repo = Path(__file__).resolve().parents[1]
    try:
        if options.run:
            raise BuildError("source execution is not enabled in migration step 0")
        config = load_config(repo)
        if options.verify_framework:
            if not options.receipt:
                raise BuildError("--verify-framework requires --receipt")
            binary = Path(os.path.abspath(options.verify_framework))
            receipt = Path(os.path.abspath(options.receipt))
            print(json.dumps(verify_framework(repo, binary, receipt, config), indent=2))
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
