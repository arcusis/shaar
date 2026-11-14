#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Compare ChromiumBridge's routed ABI with the exact pinned engine archive."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DLSYM_LITERAL = re.compile(r'\bdlsym\s*\(\s*[^,]+,\s*"(shaar_[A-Za-z0-9_]+)"\s*\)')
LOAD_MACRO = re.compile(r"(?m)^(?![ \t]*#)[ \t]*.*?\bSHAAR_LOAD\s*\(\s*\w+\s*,\s*(\w+)\s*\)")
ENUM = re.compile(r"typedef\s+enum\s*\{(?P<body>.*?)\}\s*(?P<name>\w+)\s*;", re.S)
ENUM_VALUE = re.compile(r"\b(SHAAR_(?:EVENT|OP)_[A-Z0-9_]+)\s*=")
PATCH_ENUM_VALUE = re.compile(r"^\s*(SHAAR_(?:EVENT|OP)_[A-Z0-9_]+)\s*=")
PUBLIC_HEADER = "chrome/browser/shaar/public/shaar_engine.h"
ENGINE_VERSION_TAG = re.compile(r"engine-(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*))*-shaar\.[1-9][0-9]*\Z")


class ContractError(ValueError):
    """The bridge and pinned archive do not satisfy the ABI contract."""


def bridge_files(root: Path) -> list[Path]:
    return sorted(path for path in (root / "Sources/ChromiumBridge").rglob("*")
                  if path.is_file() and path.suffix in {".h", ".m", ".mm", ".inc", ".c", ".cc", ".cpp"})


def collect_bridge_symbols(root: Path) -> set[str]:
    symbols: set[str] = set()
    for path in bridge_files(root):
        source = path.read_text(errors="replace")
        # Only string arguments passed to dlsym are ABI lookups. Other bridge
        # strings can mention a symbol name in diagnostics or documentation.
        symbols.update(DLSYM_LITERAL.findall(source))
        symbols.update("shaar_" + suffix for suffix in LOAD_MACRO.findall(source))
    return symbols


def collect_routes(root: Path) -> tuple[set[str], set[str]]:
    events: set[str] = set()
    operations: set[str] = set()
    for path in bridge_files(root):
        source = path.read_text(errors="replace")
        events.update(re.findall(r"\bSHAAR_EVENT_[A-Z0-9_]+\b", source))
        operations.update(re.findall(r"\bSHAAR_OP_[A-Z0-9_]+\b", source))
    return events, operations


def exported_symbols(binary: Path) -> set[str]:
    result = subprocess.run(["nm", "-gU", str(binary)], check=True, capture_output=True, text=True)
    return {name.removeprefix("_") for line in result.stdout.splitlines()
            if (name := line.split()[-1] if line.split() else "").startswith(("_shaar_", "shaar_"))}


def archive_members(archive: Path) -> tuple[set[str], str]:
    try:
        with tarfile.open(archive, "r:xz") as package:
            members = package.getmembers()
    except (OSError, tarfile.TarError) as error:
        raise ContractError(f"cannot read cached pinned engine archive: {error}") from error
    headers = sorted(member.name for member in members if Path(member.name).suffix == ".h")
    binaries = sorted(member.name for member in members
                      if member.isfile() and Path(member.name).name == "Chromium Framework")
    if len(binaries) != 1:
        raise ContractError("pinned engine archive must contain exactly one Chromium Framework binary")
    return set(headers), binaries[0]


def parse_header_enums(header: str) -> tuple[set[str], set[str]]:
    declared = {name: set() for name in ("shaar_event_kind", "shaar_operation")}
    for match in ENUM.finditer(header):
        name = match.group("name")
        if name in declared:
            declared[name] = set(ENUM_VALUE.findall(match.group("body")))
    if not declared["shaar_event_kind"] or not declared["shaar_operation"]:
        raise ContractError("pinned archive headers are missing the event-kind or operation enum")
    return declared["shaar_event_kind"], declared["shaar_operation"]


def patch_header_enum_changes(patch: str) -> tuple[set[str], set[str]]:
    """Return enum additions/removals in this patch's public-header sections."""
    added: set[str] = set()
    removed: set[str] = set()
    selected = False
    for line in patch.splitlines():
        if line.startswith("diff --git "):
            match = re.match(r"diff --git a/(\S+) b/(\S+)", line)
            selected = bool(match and match.group(2) == PUBLIC_HEADER)
            continue
        if line.startswith("--- a/"):
            selected = line[6:].split("\t", 1)[0] == PUBLIC_HEADER
            continue
        if not selected or not line or line.startswith(("+++", "---", "\\")):
            continue
        if line[0] not in "+-":
            continue
        match = PATCH_ENUM_VALUE.match(line[1:])
        if match:
            (added if line[0] == "+" else removed).add(match.group(1))
    return added, removed


def source_build_header(root: Path, pin: dict) -> tuple[set[str], set[str], str]:
    """Validate and reconstruct the public header from the pinned source-build inputs."""
    manifest_path = root / "ThirdParty/ChromiumEngine/source-build.json"
    manifest = json.loads(manifest_path.read_text())
    expected_version = pin["releaseTag"].removeprefix("engine-").split("-shaar.", 1)[0]
    if manifest.get("chromium", {}).get("version") != expected_version:
        raise ContractError("source-build.json Chromium version does not match the pinned engine archive")
    layer = manifest.get("layer", {})
    if layer.get("path") != "ThirdParty/ChromiumEngine/layer":
        raise ContractError("source-build.json does not identify the checked-in engine layer")
    expected_digest = layer.get("files", {}).get(PUBLIC_HEADER)
    header_path = root / layer["path"] / PUBLIC_HEADER
    if not isinstance(expected_digest, str) or not header_path.is_file():
        raise ContractError("source-build.json does not pin the public Shaar ABI header")
    actual_digest = hashlib.sha256(header_path.read_bytes()).hexdigest()
    if actual_digest != expected_digest:
        raise ContractError("public ABI header does not match its source-build.json digest")
    events, operations = parse_header_enums(header_path.read_text(errors="replace"))
    patch_count = 0
    for entry in manifest.get("patches", []):
        if not isinstance(entry, dict) or not isinstance(entry.get("file"), str):
            raise ContractError("source-build patch entry must name a relative file")
        relative_patch = Path(entry["file"])
        try:
            patch_is_inside_repository = (root / relative_patch).resolve(strict=True).is_relative_to(root.resolve())
        except FileNotFoundError:
            # Keep the dedicated missing-patch error below for ordinary absent files.
            patch_is_inside_repository = True
        except (OSError, RuntimeError):
            patch_is_inside_repository = False
        if (relative_patch.is_absolute() or ".." in relative_patch.parts
                or not patch_is_inside_repository):
            raise ContractError(f"source-build patch path escapes the repository: {entry['file']!r}")
        patch_path = root / relative_patch
        if not patch_path.is_file():
            raise ContractError(f"source-build patch is missing: {entry['file']}")
        patch_bytes = patch_path.read_bytes()
        if hashlib.sha256(patch_bytes).hexdigest() != entry.get("sha256"):
            raise ContractError(f"source-build patch digest mismatch: {entry['file']}")
        patch_text = patch_bytes.decode("utf-8", errors="replace")
        if PUBLIC_HEADER not in patch_text:
            continue
        added, removed = patch_header_enum_changes(patch_text)
        if added or removed:
            patch_count += 1
            events.update(name for name in added if name.startswith("SHAAR_EVENT_"))
            operations.update(name for name in added if name.startswith("SHAAR_OP_"))
            events.difference_update(name for name in removed if name.startswith("SHAAR_EVENT_"))
            operations.difference_update(name for name in removed if name.startswith("SHAAR_OP_"))
    return events, operations, f"hash-verified source-build header and {patch_count} ABI patch(es)"


def optional_symbols(root: Path) -> dict[str, str]:
    path = root / "ThirdParty/ChromiumEngine/abi-optional-symbols.json"
    if not path.exists():
        return {}
    data = json.loads(path.read_text())
    if not isinstance(data, dict) or data.get("schemaVersion") != 1 or not isinstance(data.get("symbols"), dict):
        raise ContractError("abi-optional-symbols.json must contain schemaVersion 1 and a symbols object")
    result = {}
    for symbol, minimum in data["symbols"].items():
        if (not re.fullmatch(r"shaar_[A-Za-z0-9_]+", symbol)
                or not isinstance(minimum, str)
                or not ENGINE_VERSION_TAG.fullmatch(minimum)):
            raise ContractError(f"invalid optional ABI symbol entry: {symbol!r}")
        result[symbol] = minimum
    return result


def release_version(tag: str) -> tuple[int, ...]:
    if not ENGINE_VERSION_TAG.fullmatch(tag):
        raise ContractError(f"invalid pinned engine release tag: {tag!r}")
    version, shaar_release = tag.removeprefix("engine-").split("-shaar.")
    return tuple(int(part) for part in version.split(".")) + (int(shaar_release),)


def check_contract(root: Path, archive: Path, *, nm=exported_symbols) -> tuple[int, int, int, str]:
    pin = json.loads((root / "ThirdParty/ChromiumEngine/pin.json").read_text())
    with archive.open("rb") as archive_file:
        digest = hashlib.file_digest(archive_file, "sha256").hexdigest()
    if digest != pin.get("sha256") or archive.name != pin.get("asset"):
        raise ContractError("cached engine archive does not match ThirdParty/ChromiumEngine/pin.json")
    _, binary_name = archive_members(archive)
    optional = optional_symbols(root)
    # The pinned framework archive is headerless. The app compiles against the
    # checked-in engine layer header; source_build_header verifies its digest
    # and source-build provenance before reading event/op declarations.
    declared_events, declared_operations, header_origin = source_build_header(root, pin)
    with tarfile.open(archive, "r:xz") as package:
        # Extract only the framework executable to a temporary file for nm.
        with tempfile.TemporaryDirectory(prefix="shaar-abi-") as directory:
            binary_file = package.extractfile(binary_name)
            if binary_file is None:
                raise ContractError("could not read Chromium Framework from pinned archive")
            binary = Path(directory) / "Chromium Framework"
            with binary.open("wb") as output:
                shutil.copyfileobj(binary_file, output, length=1024 * 1024)
            exports = nm(binary)
    pin_version = release_version(pin.get("releaseTag", ""))
    missing = sorted(
        symbol for symbol in collect_bridge_symbols(root)
        if symbol not in exports
        and (symbol not in optional or pin_version >= release_version(optional[symbol]))
    )
    if missing:
        raise ContractError("bridge symbols missing from pinned archive exports: " + ", ".join(missing))
    events, operations = collect_routes(root)
    absent_events = sorted(events - declared_events)
    absent_operations = sorted(operations - declared_operations)
    if absent_events or absent_operations:
        problems = []
        if absent_events:
            problems.append("events " + ", ".join(absent_events))
        if absent_operations:
            problems.append("operations " + ", ".join(absent_operations))
        raise ContractError("app routes ABI values absent from pinned archive headers: " + "; ".join(problems))
    return len(collect_bridge_symbols(root)), len(events), len(operations), header_origin


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path)
    options = parser.parse_args()
    pin = json.loads((ROOT / "ThirdParty/ChromiumEngine/pin.json").read_text())
    archive = options.archive or ROOT / "build/EngineCache" / pin["asset"]
    if not archive.is_file():
        print(f"cached pinned engine archive is missing: {archive}; refusing network fetch", file=sys.stderr)
        return 1
    try:
        symbols, events, operations, header_origin = check_contract(ROOT, archive)
    except (ContractError, OSError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        return 1
    print(f"ABI contract passed: {symbols} bridge symbols, {events} event kinds, {operations} operations; "
          f"declarations from {header_origin}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
