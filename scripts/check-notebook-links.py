#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Fail when a Notebook note has no direct wiki link from an _INDEX_*.md file."""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys


DEFAULT_NOTEBOOK = Path(__file__).resolve().parents[1] / "Notebook"
WIKI_LINK = re.compile(r"\[\[([^\]\n]+)\]\]")


def index_text(path: Path) -> str:
    """Exclude comments and fenced examples, which are not navigation links."""
    text = re.sub(r"<!--.*?-->", "", path.read_text(encoding="utf-8"), flags=re.DOTALL)
    lines = []
    fence = None
    for line in text.splitlines():
        marker = re.match(r"^\s{0,3}(`{3,}|~{3,})(.*)$", line)
        if fence is not None:
            if marker and marker[1][0] == fence[0] and len(marker[1]) >= len(fence) and not marker[2].strip():
                fence = None
        elif marker:
            fence = marker[1]
        else:
            lines.append(re.sub(r"(`+).*?\1", "", line))
    return "\n".join(lines)


def linked_notes(indexes: list[Path]) -> set[Path]:
    linked = set()
    for index in indexes:
        for match in WIKI_LINK.finditer(index_text(index)):
            target = match[1].split("|", 1)[0].split("#", 1)[0].strip()
            if not target:
                continue
            if target.startswith("Notebook/"):
                target = target.removeprefix("Notebook/")
            if not target.endswith(".md"):
                target += ".md"
            linked.add((index.parent / target).resolve())
    return linked


def check_notebook(notebook: Path) -> int:
    notes = sorted(notebook.rglob("*.md"))
    indexes = [path for path in notes if path.name.startswith("_INDEX_")]
    if not indexes:
        print(f"No _INDEX_*.md files found in {notebook}", file=sys.stderr)
        return 1
    linked = linked_notes(indexes)
    orphans = [path for path in notes if path not in indexes and path.resolve() not in linked]
    for path in orphans:
        print(f"Note not linked from any index: {path.relative_to(notebook)}", file=sys.stderr)
    if orphans:
        return 1
    print(f"Notebook links OK: {len(notes) - len(indexes)} notes, {len(indexes)} indexes")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--notebook", type=Path, default=DEFAULT_NOTEBOOK)
    args = parser.parse_args()
    try:
        return check_notebook(args.notebook.resolve())
    except (OSError, UnicodeError) as error:
        print(f"Cannot check Notebook links: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
