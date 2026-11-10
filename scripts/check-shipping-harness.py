#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Fail when the shipping app or its bridge still contains a verification harness.

The check is structural. It reads the verification sources, then rejects those
symbols and harness launch flags in Sources/ArcusisBrowser, Sources/ChromiumBridge,
and, when asked, in the built shipping executable. Dispatch flags that do not
contain probe or smoke, such as a route smoke, are included. A flag the shipping
sources also use is left alone. A hyphenated fixture id quoted only by
verification, such as a click target, is rejected too. There is no
hand-maintained list of probe names.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


SHIPPING_ROOTS = ("Sources/ArcusisBrowser", "Sources/ChromiumBridge")
VERIFICATION_ROOTS = ("Sources/ShaarVerification", "Sources/ChromiumBridgeVerification")
SOURCE_SUFFIXES = {".swift", ".m", ".mm", ".h", ".inc", ".c", ".cc", ".cpp"}
MODULE_NAMES = ("ShaarVerification", "ChromiumBridgeVerification")
TYPE_RE = re.compile(
    r"^(?:@[A-Za-z0-9_]+(?:\([^)\n]*\))?\s+"
    r"|public\s+|internal\s+|open\s+|private\s+|fileprivate\s+|final\s+|nonisolated\s+)*"
    r"(?:enum|struct|class|actor|protocol)\s+([A-Z][A-Za-z0-9_]+)\b",
    re.MULTILINE,
)
EXPORT_RE = re.compile(r"^FOUNDATION_EXPORT\s+.+?\b(ARC[A-Za-z0-9_]+)\s*\(", re.MULTILINE)
METHOD_RE = re.compile(
    r"^[-+]\s*\([^;\n]*\)\s*((?:[A-Za-z_][A-Za-z0-9_]*)?(?:Probe|Smoke)[A-Za-z0-9_]*)",
    re.MULTILINE,
)
FLAG_RE = re.compile(r"--[A-Za-z0-9-]*(?:probe|smoke)(?:-[A-Za-z0-9-]+)?\b")
TESTING_RE = re.compile(r"testing:\s*true\b")
FLAG_LITERAL_RE = re.compile(r"--[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*")
HARNESS_FLAG_RE = re.compile(r"(?:probe|smoke|qa)(?:-|$)")
# A dispatch flag such as --devtools-f12-route has no probe or smoke token.
DISPATCH_RE = re.compile(
    r"(?:contains\(\s*|firstIndex\(of:\s*|harnessLaunch\(\s*)\"(--[A-Za-z0-9-]+)\""
)
TESTING_BYTES = re.compile(br"testing:\s*true\b")
FLAG_BYTES = re.compile(br"--[A-Za-z0-9-]*(?:probe|smoke)(?:-[A-Za-z0-9-]+)?\b")
# Fixture ids such as parity-action. Ordinary product words such as font-style
# are left alone: a segment must name the harness.
HARNESS_ID_RE = re.compile(
    r"^(?:[a-z0-9]+-)*(?:probe|parity|smoke|harness)(?:-[a-z0-9]+)*$"
)
OBJC_STRING_RE = re.compile(r'@"([^"\\\n]*)"')
SWIFT_STRING_RE = re.compile(r'(?<![A-Za-z0-9_\\@])"([^"\\\n]*)"')


def source_files(root: Path, relative: str) -> list[Path]:
    directory = root / relative
    if not directory.is_dir():
        return []
    return [
        path for path in directory.rglob("*")
        if path.is_file() and path.suffix in SOURCE_SUFFIXES
    ]


def declared_types(text: str) -> set[str]:
    return {match.group(1) for match in TYPE_RE.finditer(text) if len(match.group(1)) >= 8}


def method_names(name: str) -> set[str]:
    names = {name}
    stem = re.sub(r"(?:In|For|With|From)[A-Z].*$", "", name)
    if stem != name and len(stem) >= 12 and re.search(r"Probe|Smoke", stem):
        names.add(stem)
    return names


def verification_symbols(root: Path) -> set[str]:
    symbols = set(MODULE_NAMES)
    for relative in VERIFICATION_ROOTS:
        for path in source_files(root, relative):
            text = path.read_text(encoding="utf-8", errors="replace")
            symbols.update(declared_types(text))
            symbols.update(match.group(1) for match in EXPORT_RE.finditer(text))
            for match in METHOD_RE.finditer(text):
                symbols.update(method_names(match.group(1)))
    owned_by_shipping = set()
    for relative in SHIPPING_ROOTS:
        for path in source_files(root, relative):
            text = path.read_text(encoding="utf-8", errors="replace")
            owned_by_shipping.update(declared_types(text))
            owned_by_shipping.update(match.group(1) for match in EXPORT_RE.finditer(text))
            for match in METHOD_RE.finditer(text):
                owned_by_shipping.update(method_names(match.group(1)))
    return {symbol for symbol in symbols if symbol not in owned_by_shipping and len(symbol) >= 8}


def quoted_strings(text: str) -> list[str]:
    return [match.group(1) for match in OBJC_STRING_RE.finditer(text)] + [
        match.group(1) for match in SWIFT_STRING_RE.finditer(text)
    ]


def probe_ids(root: Path) -> set[str]:
    found = set()
    for relative in VERIFICATION_ROOTS:
        for path in source_files(root, relative):
            text = path.read_text(encoding="utf-8", errors="replace")
            for value in quoted_strings(text):
                if "-" in value and HARNESS_ID_RE.fullmatch(value):
                    found.add(value)
    return found


def harness_flags(root: Path) -> set[str]:
    flags = set()
    dispatch = set()
    for relative in VERIFICATION_ROOTS:
        for path in source_files(root, relative):
            text = path.read_text(encoding="utf-8", errors="replace")
            for flag in FLAG_LITERAL_RE.findall(text):
                if HARNESS_FLAG_RE.search(flag):
                    flags.add(flag)
            dispatch.update(DISPATCH_RE.findall(text))
    # A product flag the harness also mentions stays legal in the shipping app.
    shared = set()
    for relative in SHIPPING_ROOTS:
        for path in source_files(root, relative):
            text = path.read_text(encoding="utf-8", errors="replace")
            shared.update(FLAG_LITERAL_RE.findall(text))
    return flags | (dispatch - shared)


def line_findings(
    path: Path, text: str, symbols: set[str], flags: set[str], ids: set[str]
) -> list[str]:
    found = []
    symbol_re = None
    if symbols:
        symbol_re = re.compile(r"\b(?:" + "|".join(re.escape(symbol) for symbol in sorted(symbols)) + r")\b")
    flag_re = None
    if flags:
        flag_re = re.compile(r"(?:" + "|".join(re.escape(flag) for flag in sorted(flags)) + r")\b")
    id_re = None
    if ids:
        id_re = re.compile(
            r"(?<![A-Za-z0-9-])(?:"
            + "|".join(re.escape(item) for item in sorted(ids))
            + r")(?![A-Za-z0-9-])"
        )
    for number, line in enumerate(text.splitlines(), 1):
        if TESTING_RE.search(line):
            found.append(f"{path}:{number}: testing: true")
        probe_flag = FLAG_RE.search(line)
        if probe_flag:
            found.append(f"{path}:{number}: {probe_flag.group(0)}")
        elif flag_re:
            literal = flag_re.search(line)
            if literal:
                found.append(f"{path}:{number}: {literal.group(0)}")
        if symbol_re:
            symbol = symbol_re.search(line)
            if symbol:
                found.append(f"{path}:{number}: {symbol.group(0)}")
        if id_re:
            fixture = id_re.search(line)
            if fixture:
                found.append(f"{path}:{number}: {fixture.group(0)}")
    return found


def source_findings(root: Path, symbols: set[str], flags: set[str], ids: set[str]) -> list[str]:
    found = []
    for relative in SHIPPING_ROOTS:
        for path in source_files(root, relative):
            text = path.read_text(encoding="utf-8", errors="replace")
            found.extend(line_findings(path, text, symbols, flags, ids))
    return found


def identifier_byte(value: int) -> bool:
    return value == 95 or 48 <= value <= 57 or 65 <= value <= 90 or 97 <= value <= 122


def hyphen_byte(value: int) -> bool:
    return identifier_byte(value) or value == 45


def bounded(data: bytes, start: int, end: int, boundary=identifier_byte) -> bool:
    before = data[start - 1] if start else 0
    after = data[end] if end < len(data) else 0
    return not boundary(before) and not boundary(after)


def first_bounded(data: bytes, needle: bytes, boundary=identifier_byte) -> bool:
    start = data.find(needle)
    while start != -1:
        if bounded(data, start, start + len(needle), boundary):
            return True
        start = data.find(needle, start + 1)
    return False


def binary_findings(path: Path, symbols: set[str], flags: set[str], ids: set[str]) -> list[str]:
    if not path.is_file():
        return [f"{path}: shipping executable is missing"]
    data = path.read_bytes()
    found = []
    for label in sorted(symbols | flags):
        if first_bounded(data, label.encode("utf-8")):
            found.append(f"{path}: {label}")
    for label in sorted(ids):
        if first_bounded(data, label.encode("utf-8"), hyphen_byte):
            found.append(f"{path}: {label}")
    for match in FLAG_BYTES.finditer(data):
        text = match.group(0).decode("ascii")
        if f"{path}: {text}" not in found:
            found.append(f"{path}: {text}")
    if TESTING_BYTES.search(data):
        found.append(f"{path}: testing: true")
    return found


def findings(root: Path, binary: Path | None = None) -> list[str]:
    symbols = verification_symbols(root)
    flags = harness_flags(root)
    ids = probe_ids(root)
    found = source_findings(root, symbols, flags, ids)
    if binary is not None:
        found.extend(binary_findings(binary, symbols, flags, ids))
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--binary", type=Path)
    options = parser.parse_args()
    found = findings(options.root, options.binary)
    if not found:
        return 0
    print("Verification code found in the shipping app.", file=sys.stderr)
    for item in found:
        print(item, file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
