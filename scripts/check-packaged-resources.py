#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Fail when shipping Swift calls Bundle.module outside PackagedResourceBundle.resolve."""

from __future__ import annotations

import re
import sys
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
SHIPPING_SOURCE_ROOTS = (
    "Sources/ArcusisBrowser",
    "Sources/BrowserCore",
    "Sources/ChromiumBridge",
    "Sources/CSQLite",
    "Sources/Shaar",
    "Sources/ShaarEngineABI",
    "Sources/ShaarEngineC",
)
MODULE_TOKEN = re.compile(r"Bundle\.module|(?<![\w.])\.module\b")
FALLBACK_CLOSURE = re.compile(r"\{\s*\.module\s*\}")


def code_portion(line: str, block_comment_depth: list[int] | None = None) -> str:
    if block_comment_depth is None:
        block_comment_depth = [0]
    code = []
    quoted = False
    escaped = False
    literal_start = 0
    interpolated = False
    interpolation_depth = 0
    pending_interpolation = False
    interpolation_start = 0
    interpolation_ranges = []
    skip_next = False
    quote_hashes = 0
    for index, character in enumerate(line):
        if skip_next:
            skip_next = False
            continue
        if not quoted and block_comment_depth[0]:
            if line.startswith("/*", index):
                block_comment_depth[0] += 1
                code.extend((" ", " "))
                skip_next = True
            elif line.startswith("*/", index):
                block_comment_depth[0] -= 1
                code.extend((" ", " "))
                skip_next = True
            else:
                code.append(" ")
            continue
        if not quoted and line.startswith("/*", index):
            block_comment_depth[0] = 1
            code.extend((" ", " "))
            skip_next = True
            continue
        if quoted:
            code.append(character)
            if interpolation_depth:
                if character == "(":
                    interpolation_depth += 1
                elif character == ")":
                    interpolation_depth -= 1
                    if interpolation_depth == 0:
                        interpolation_ranges.append((interpolation_start, len(code) - 1))
            elif pending_interpolation and character == "(":
                interpolation_depth = 1
                interpolation_start = len(code)
                pending_interpolation = False
                escaped = False
            elif escaped:
                if character == "(":
                    interpolated = True
                escaped = False
            elif character == "\\":
                escaped = True
                cursor = index + 1
                hashes = 0
                while cursor < len(line) and line[cursor] == "#":
                    cursor += 1
                    hashes += 1
                if (
                    hashes == quote_hashes
                    and cursor < len(line)
                    and line[cursor] == "("
                ):
                    interpolated = True
                    pending_interpolation = True
            elif character == '"':
                cursor = index + 1
                hashes = 0
                while cursor < len(line) and line[cursor] == "#":
                    cursor += 1
                    hashes += 1
                if hashes == quote_hashes:
                    quoted = False
                    if not interpolated:
                        code[literal_start:] = [" "] * (len(code) - literal_start)
                    elif interpolation_ranges:
                        keep = {
                            offset
                            for start, end in interpolation_ranges
                            for offset in range(start, end)
                        }
                        code[literal_start:] = [
                            value if offset in keep else " "
                            for offset, value in enumerate(code[literal_start:], start=literal_start)
                        ]
        elif character == '"':
            quoted = True
            cursor = index - 1
            quote_hashes = 0
            while cursor >= 0 and line[cursor] == "#":
                cursor -= 1
                quote_hashes += 1
            literal_start = len(code) - quote_hashes
            interpolated = False
            interpolation_depth = 0
            pending_interpolation = False
            interpolation_ranges = []
            code.append(character)
        elif line.startswith("//", index):
            break
        else:
            code.append(character)
    return "".join(code)


def code_lines(lines: list[str]) -> list[str]:
    block_comment_depth = [0]
    return [code_portion(line, block_comment_depth) for line in lines]


def violations_in_source(text: str, path: str) -> list[str]:
    lines = text.splitlines()
    code = code_lines(lines)
    errors = []
    for index, line in enumerate(code):
        if not MODULE_TOKEN.search(line):
            continue
        if "Bundle.module" in line or not fallback_only(line, code, index):
            errors.append(
                f"{path}:{index + 1}: Bundle.module in a shipping target must be the "
                "development fallback passed to PackagedResourceBundle.resolve"
            )
    return errors

def fallback_only(line: str, lines: list[str], index: int) -> bool:
    window = "\n".join(lines[max(0, index - 5) : index + 1])
    if "PackagedResourceBundle.resolve(" not in window:
        return False
    remainder = FALLBACK_CLOSURE.sub("", line)
    return MODULE_TOKEN.search(remainder) is None


def shipping_swift_files(root: Path) -> list[Path]:
    files = []
    for relative in SHIPPING_SOURCE_ROOTS:
        directory = root / relative
        if directory.is_dir():
            files.extend(path for path in directory.rglob("*.swift") if path.is_file())
    return sorted(files)


def violations_in_tree(root: Path) -> list[str]:
    errors = []
    for path in shipping_swift_files(root):
        text = path.read_text(encoding="utf-8")
        errors.extend(violations_in_source(text, path.relative_to(root).as_posix()))
    return errors


def main() -> int:
    errors = violations_in_tree(REPOSITORY_ROOT)
    for error in errors:
        print(error, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
