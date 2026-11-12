#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Fail when a shipping source or the shipping executable still contains a harness.

The check is structural. It reads the verification sources, then rejects those
symbols, harness launch flags, and fixture ids in every other Sources directory
and, when asked, in the built shipping executable. Dispatch flags that do not
contain probe or smoke, such as a route smoke, are included. The only launch
flag exempted on purpose is --render-preview. A hyphenated fixture id with a
probe, parity, smoke, or harness segment is rejected too. Reads of
SHAAR_ENGINE_TESTING are rejected outside the engine start that sets the
variable. There is no hand-maintained list of probe names.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


VERIFICATION_ROOTS = ("Sources/ShaarVerification", "Sources/ChromiumBridgeVerification")
VERIFICATION_DIRS = {"ShaarVerification", "ChromiumBridgeVerification"}
SOURCE_SUFFIXES = {".swift", ".m", ".mm", ".h", ".inc", ".c", ".cc", ".cpp"}
MODULE_NAMES = ("ShaarVerification", "ChromiumBridgeVerification")
# Product launch flags a harness may also mention. Anything else stays banned.
PRODUCT_FLAGS = {"--render-preview"}
TYPE_RE = re.compile(
    r"^[ \t]*(?:@[A-Za-z0-9_]+(?:\([^)\n]*\))?\s+"
    r"|public\s+|internal\s+|open\s+|private\s+|fileprivate\s+|final\s+|nonisolated\s+)*"
    r"(?:enum|struct|class|actor|protocol)\s+([A-Z][A-Za-z0-9_]+)\b",
    re.MULTILINE,
)
EXPORT_RE = re.compile(
    r"^[ \t]*FOUNDATION_EXPORT\s+.+?\b(ARC[A-Za-z0-9_]+)\s*\(",
    re.MULTILINE,
)
METHOD_RE = re.compile(
    r"^[ \t]*[-+]\s*\([^;\n]*\)\s*"
    r"((?:[A-Za-z_][A-Za-z0-9_]*)?(?:[Pp]robe|[Ss]moke)[A-Za-z0-9_]*)",
    re.MULTILINE,
)
SWIFT_FUNC_RE = re.compile(
    r"^[ \t]*(?:@[A-Za-z0-9_]+(?:\([^)\n]*\))?\s+"
    r"|public\s+|internal\s+|open\s+|private\s+|fileprivate\s+|final\s+"
    r"|static\s+|override\s+|nonisolated\s+)*"
    r"func\s+((?:[A-Za-z_][A-Za-z0-9_]*)?(?:[Pp]robe|[Ss]moke)[A-Za-z0-9_]*)\b",
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
OBJC_STRING_RE = re.compile(r'@"((?:[^"\\\n]|\\.)*)"')
SWIFT_STRING_RE = re.compile(r'(?<![A-Za-z0-9_\\@])"((?:[^"\\\n]|\\.)*)"')
ENGINE_TESTING = "SHAAR_ENGINE_TESTING"
PROBE_OPERATION_RE = re.compile(r"\bSHAAR_OP_PROBE_[A-Z0-9_]+\b")
ENGINE_TESTING_WRITE = re.compile(
    r'\b(?:setenv|unsetenv)\s*\(\s*"SHAAR_ENGINE_TESTING"'
)


def shipping_roots(root: Path) -> list[str]:
    sources = root / "Sources"
    if not sources.is_dir():
        return []
    return sorted(
        f"Sources/{path.name}"
        for path in sources.iterdir()
        if path.is_dir() and path.name not in VERIFICATION_DIRS
    )


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
    if stem != name and len(stem) >= 12 and re.search(r"[Pp]robe|[Ss]moke", stem):
        names.add(stem)
    return names


def declared_symbols(text: str) -> set[str]:
    found = set(declared_types(text))
    found.update(match.group(1) for match in EXPORT_RE.finditer(text))
    for pattern in (METHOD_RE, SWIFT_FUNC_RE):
        for match in pattern.finditer(text):
            found.update(method_names(match.group(1)))
    return found


def verification_symbols(root: Path) -> set[str]:
    symbols = set(MODULE_NAMES)
    for relative in VERIFICATION_ROOTS:
        for path in source_files(root, relative):
            text = path.read_text(encoding="utf-8", errors="replace")
            symbols.update(declared_symbols(text))
    owned_by_shipping = set()
    for relative in shipping_roots(root):
        for path in source_files(root, relative):
            text = path.read_text(encoding="utf-8", errors="replace")
            owned_by_shipping.update(declared_symbols(text))
    return {symbol for symbol in symbols if symbol not in owned_by_shipping and len(symbol) >= 8}


def quoted_strings(text: str) -> list[str]:
    raw = [match.group(1) for match in OBJC_STRING_RE.finditer(text)]
    raw += [match.group(1) for match in SWIFT_STRING_RE.finditer(text)]
    return [
        value.replace(r"\n", "\n").replace(r"\t", "\t").replace(r"\"", '"').strip()
        for value in raw
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
    return (flags | dispatch) - PRODUCT_FLAGS


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
        # The removed title channel is not a type or a launch flag.
        if "shaar-chooser:" in line:
            found.append(f"{path}:{number}: shaar-chooser:")
        if id_re:
            fixture = id_re.search(line)
            if fixture:
                found.append(f"{path}:{number}: {fixture.group(0)}")
    return found


def strip_comments(text: str) -> str:
    """Replace comments with spaces while preserving strings and line numbers."""
    result = list(text)
    index = 0
    quote = None
    while index < len(text):
        char = text[index]
        if quote:
            if quote != '"""' and char == "\n":
                quote = None
                index += 1
                continue
            if quote == '"""' and text.startswith('"""', index):
                quote = None
                index += 3
                continue
            if char == "\\":
                index += 2
                continue
            if quote != '"""' and char == quote:
                quote = None
            index += 1
            continue
        if text.startswith('"""', index):
            quote = '"""'
            index += 3
            continue
        if char in ('"', "'"):
            quote = char
            index += 1
            continue
        if text.startswith("//", index):
            end = text.find("\n", index)
            end = len(text) if end == -1 else end
            for position in range(index, end):
                result[position] = " "
            index = end
            continue
        if text.startswith("/*", index):
            end = index + 2
            depth = 1
            while end < len(text) and depth:
                if text.startswith("/*", end):
                    depth += 1
                    end += 2
                elif text.startswith("*/", end):
                    depth -= 1
                    end += 2
                else:
                    end += 1
            for position in range(index, end):
                if result[position] != "\n":
                    result[position] = " "
            index = end
            continue
        index += 1
    return "".join(result)


def engine_testing_findings(path: Path, text: str) -> list[str]:
    """Only lines compiled solely for verification may reference the engine test variable."""
    cleaned = strip_comments(text)
    verification_lines = set()
    verification_guard = re.compile(
        r"^(?:defined\s*\(?\s*SHAAR_VERIFICATION\s*\)?|ifdef\s+SHAAR_VERIFICATION)$"
    )
    stack = []
    verification_only = False
    for line_number, line in enumerate(cleaned.splitlines(keepends=True), start=1):
        directive = re.match(r"^[ \t]*#[ \t]*(if|ifdef|ifndef|elif|else|endif)\b(.*)", line)
        if directive:
            command, expression = directive.groups()
            expression = expression.strip()
            if command in {"if", "ifdef", "ifndef"}:
                parent_only = verification_only
                positive = command == "ifdef" and expression == "SHAAR_VERIFICATION"
                positive = positive or (command == "if" and bool(verification_guard.fullmatch(expression)))
                stack.append({"parent": parent_only})
                verification_only = parent_only or positive
            elif command == "elif" and stack:
                frame = stack[-1]
                verification_only = frame["parent"] or bool(verification_guard.fullmatch(expression))
            elif command == "else" and stack:
                verification_only = stack[-1]["parent"]
            elif command == "endif" and stack:
                frame = stack.pop()
                verification_only = frame["parent"]
        if verification_only:
            verification_lines.add(line_number)
    allowed = engine_start_span(path, text)
    allowed_writes = {
        match.start() + match.group(0).index(ENGINE_TESTING)
        for match in ENGINE_TESTING_WRITE.finditer(cleaned)
        if allowed and allowed[0] <= match.start() < allowed[1]
    }
    found = []
    for match in re.finditer(re.escape(ENGINE_TESTING), cleaned):
        if match.start() in allowed_writes:
            continue
        number = cleaned.count("\n", 0, match.start()) + 1
        if number not in verification_lines:
            found.append(f"{path}:{number}: {ENGINE_TESTING}")
    return found


def source_findings(root: Path, symbols: set[str], flags: set[str], ids: set[str]) -> list[str]:
    found = []
    for relative in shipping_roots(root):
        for path in source_files(root, relative):
            text = path.read_text(encoding="utf-8", errors="replace")
            found.extend(line_findings(path, text, symbols, flags, ids))
            found.extend(engine_testing_findings(path, text))
            found.extend(
                f"{path}:{text.count(chr(10), 0, match.start()) + 1}: {match.group(0)}"
                for match in PROBE_OPERATION_RE.finditer(strip_comments(text))
            )
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


def symbol_present(data: bytes, name: bytes) -> bool:
    """Match a bare name, an underscore prefix, or a Swift length prefix.

    `118Name` does not match an 18-character name: the byte before the length
    digits is another digit. A letter before the length, as in Swift mangling,
    does match.
    """
    if first_bounded(data, name):
        return True
    underscored = b"_" + name
    start = data.find(underscored)
    while start != -1:
        before = data[start - 1] if start else 0
        end = start + len(underscored)
        after = data[end] if end < len(data) else 0
        if not identifier_byte(before) and not identifier_byte(after):
            return True
        start = data.find(underscored, start + 1)
    prefix = str(len(name)).encode("ascii")
    needle = prefix + name
    start = data.find(needle)
    while start != -1:
        before = data[start - 1] if start else 0
        end = start + len(needle)
        after = data[end] if end < len(data) else 0
        if not (48 <= before <= 57) and not identifier_byte(after):
            return True
        start = data.find(needle, start + 1)
    return False


def binary_symbol_is_harness(name: str) -> bool:
    if name.startswith(("ShaarVerification", "ChromiumBridgeVerification")):
        return True
    separated = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1-\2", name)
    separated = re.sub(r"([a-z0-9])([A-Z])", r"\1-\2", separated).lower()
    return bool(re.search(r"(?:^|-)(?:probe|parity|smoke|harness|qa)(?:-|$)", separated))


def binary_findings(path: Path, symbols: set[str], flags: set[str], ids: set[str]) -> list[str]:
    if not path.is_file():
        return [f"{path}: shipping executable is missing"]
    data = path.read_bytes()
    found = []
    for label in sorted(symbols):
        if binary_symbol_is_harness(label) and symbol_present(data, label.encode("utf-8")):
            found.append(f"{path}: {label}")
    for label in sorted(flags):
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
    if ENGINE_TESTING.encode("ascii") in data:
        found.append(f"{path}: {ENGINE_TESTING}")
    for match in re.finditer(br"SHAAR_OP_PROBE_[A-Z0-9_]+", data):
        found.append(f"{path}: {match.group(0).decode('ascii')}")
    # The removed title channel is not a type or a launch flag.
    if b"shaar-chooser:" in data:
        found.append(f"{path}: shaar-chooser:")
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
