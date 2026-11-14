#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep Chromium framework localizations used by Shaar's en/he language picker."""

import json
import re
import shutil
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
STAGE = ROOT / "build/ShaarEnginePackage/stage"
KEEP = re.compile(r"^(?:base|en|en_GB|he)(?:_(?:FEMININE|MASCULINE|NEUTER))?\.lproj$")


def size(path: Path) -> int:
    return sum(file.stat().st_size for file in path.rglob("*") if file.is_file() and not file.is_symlink())


def trim_locales(resources: Path) -> dict:
    locale_entries = sorted(path for path in resources.iterdir() if path.name.endswith(".lproj"))
    invalid = [path.name for path in locale_entries if path.is_symlink() or not path.is_dir()]
    if invalid:
        raise ValueError("Chromium locale entries must be real directories: " + ", ".join(invalid))
    locales = locale_entries
    names = {path.name for path in locales}
    if not {"en.lproj", "he.lproj"} <= names:
        raise ValueError("Chromium framework must contain en.lproj and he.lproj")
    removed = [path for path in locales if not KEEP.fullmatch(path.name)]
    saved = sum(size(path) for path in removed)
    for path in removed:
        shutil.rmtree(path)
    return {
        "retained": [path.name for path in locales if path not in removed],
        "removedCount": len(removed),
        "removedBytes": saved,
    }


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: trim-engine-locales.py STAGED_FRAMEWORK")
    framework = Path(sys.argv[1]).resolve()
    if not framework.is_relative_to(STAGE.resolve()):
        raise SystemExit("Refusing to trim outside the owned package stage")
    resources = (framework / "Versions/Current/Resources").resolve()
    if not resources.is_relative_to(framework):
        raise SystemExit("Refusing to trim resources outside the framework")
    if not resources.is_dir():
        raise SystemExit(f"Missing framework resources: {resources}")
    print(json.dumps(trim_locales(resources), sort_keys=True))


if __name__ == "__main__":
    main()
