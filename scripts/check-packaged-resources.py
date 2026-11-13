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


def code_portion(line: str) -> str:
    quoted = False
    escaped = False
    for index, character in enumerate(line):
        if quoted:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                quoted = False
        elif character == '"':
            quoted = True
        elif line.startswith("//", index):
            return line[:index]
    return line


def violations_in_source(text: str, path: str) -> list[str]:
    lines = text.splitlines()
    errors = []
    for index, line in enumerate(lines):
        code = code_portion(line)
        if not MODULE_TOKEN.search(code):
            continue
        if "Bundle.module" in code or not fallback_only(code, lines, index):
            errors.append(
                f"{path}:{index + 1}: Bundle.module in a shipping target must be the "
                "development fallback passed to PackagedResourceBundle.resolve"
            )
    return errors


def fallback_only(line: str, lines: list[str], index: int) -> bool:
    window = "\n".join(code_portion(candidate) for candidate in lines[max(0, index - 5) : index + 1])
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
