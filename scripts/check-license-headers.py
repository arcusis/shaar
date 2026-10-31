#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Fail when a tracked source file lacks the MPL-2.0 Exhibit A notice."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
EXCLUDED_DIRECTORIES = ("ThirdParty/",)
NOTICE_LINES = (
    "This Source Code Form is subject to the terms of the Mozilla Public",
    "License, v. 2.0. If a copy of the MPL was not distributed with this",
    "file, You can obtain one at https://mozilla.org/MPL/2.0/.",
)
COMMENT_PREFIX_BY_SUFFIX = {
    ".swift": "//",
    ".h": "//",
    ".m": "//",
    ".mm": "//",
    ".py": "#",
    ".sh": "#",
}
# Lines that must stay first in their file: interpreter lines and the SwiftPM tools version.
PREAMBLE_PREFIXES = ("#!", "// swift-tools-version")


def expected_notice(path: Path) -> list[str] | None:
    prefix = COMMENT_PREFIX_BY_SUFFIX.get(path.suffix)
    if prefix is None:
        return None
    return [f"{prefix} {line}" for line in NOTICE_LINES]


def has_notice(path: Path, notice: list[str]) -> bool:
    lines = path.read_text(encoding="utf-8").splitlines()
    start = 1 if lines and lines[0].startswith(PREAMBLE_PREFIXES) else 0
    return lines[start : start + len(notice)] == notice


def tracked_files(root: Path) -> list[Path]:
    output = subprocess.run(
        ["git", "ls-files", "-z"], cwd=root, check=True, capture_output=True, text=True
    ).stdout
    return [Path(name) for name in output.split("\0") if name]


def files_missing_notice(root: Path, paths: list[Path]) -> list[Path]:
    missing = []
    for path in paths:
        if path.as_posix().startswith(EXCLUDED_DIRECTORIES):
            continue
        notice = expected_notice(path)
        if notice is not None and not has_notice(root / path, notice):
            missing.append(path)
    return missing


def main() -> int:
    missing = files_missing_notice(REPOSITORY_ROOT, tracked_files(REPOSITORY_ROOT))
    for path in missing:
        print(f"Missing MPL-2.0 header: {path}", file=sys.stderr)
    return 1 if missing else 0


if __name__ == "__main__":
    raise SystemExit(main())
