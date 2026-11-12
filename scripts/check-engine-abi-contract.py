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
SYMBOL_LITERAL = re.compile(r'"(shaar_[A-Za-z0-9_]+)"')
LOAD_MACRO = re.compile(r"\bSHAAR_LOAD\s*\(\s*\w+\s*,\s*(\w+)\s*\)")
ENUM = re.compile(r"typedef\s+enum\s*\{(?P<body>.*?)\}\s*(?P<name>\w+)\s*;", re.S)
ENUM_VALUE = re.compile(r"\b(SHAAR_(?:EVENT|OP)_[A-Z0-9_]+)\s*=")


class ContractError(ValueError):
    """The bridge and pinned archive do not satisfy the ABI contract."""


def bridge_files(root: Path) -> list[Path]:
    return sorted(path for path in (root / "Sources/ChromiumBridge").rglob("*")
                  if path.is_file() and path.suffix in {".h", ".m", ".mm", ".inc", ".c", ".cc", ".cpp"})


def collect_bridge_symbols(root: Path) -> set[str]:
    symbols: set[str] = set()
    for path in bridge_files(root):
        source = path.read_text(errors="replace")
        symbols.update(SYMBOL_LITERAL.findall(source))
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
    if not headers:
        raise ContractError("pinned engine archive does not ship C/C++ headers")
    if not binaries:
        raise ContractError("pinned engine archive does not contain Chromium Framework")
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
                or not re.fullmatch(r"engine-[0-9.]+-shaar\.[0-9]+", minimum)):
            raise ContractError(f"invalid optional ABI symbol entry: {symbol!r}")
        result[symbol] = minimum
    return result


def release_version(tag: str) -> tuple[int, ...]:
    match = re.fullmatch(r"engine-([0-9.]+)-shaar\.([0-9]+)", tag)
    if not match:
        raise ContractError(f"invalid pinned engine release tag: {tag!r}")
    return tuple(int(part) for part in match.group(1).split(".")) + (int(match.group(2)),)


def check_contract(root: Path, archive: Path, *, nm=exported_symbols) -> tuple[int, int, int]:
    pin = json.loads((root / "ThirdParty/ChromiumEngine/pin.json").read_text())
    with archive.open("rb") as archive_file:
        digest = hashlib.file_digest(archive_file, "sha256").hexdigest()
    if digest != pin.get("sha256") or archive.name != pin.get("asset"):
        raise ContractError("cached engine archive does not match ThirdParty/ChromiumEngine/pin.json")
    header_names, binary_name = archive_members(archive)
    optional = optional_symbols(root)
    with tarfile.open(archive, "r:xz") as package:
        header_sources = []
        for header_name in sorted(header_names):
            header_file = package.extractfile(header_name)
            if header_file is not None:
                header_sources.append(header_file.read().decode("utf-8", errors="replace"))
        header = "\n".join(header_sources)
        if not header:
            raise ContractError("could not read C/C++ headers from pinned archive")
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
    declared_events, declared_operations = parse_header_enums(header)
    absent_events = sorted(events - declared_events)
    absent_operations = sorted(operations - declared_operations)
    if absent_events or absent_operations:
        problems = []
        if absent_events:
            problems.append("events " + ", ".join(absent_events))
        if absent_operations:
            problems.append("operations " + ", ".join(absent_operations))
        raise ContractError("app routes ABI values absent from pinned archive headers: " + "; ".join(problems))
    return len(collect_bridge_symbols(root)), len(events), len(operations)


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
        symbols, events, operations = check_contract(ROOT, archive)
    except (ContractError, OSError, json.JSONDecodeError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        return 1
    print(f"ABI contract passed: {symbols} bridge symbols, {events} event kinds, {operations} operations")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
