#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Copy the Shaar DevTools frontend overlay into a Chromium tree."""

import argparse
import os
from pathlib import Path
import shutil


ROOT = Path(__file__).resolve().parents[1]
OVERLAY = (
    ROOT / "ThirdParty/ChromiumEngine/devtools-frontend/front_end/panels/shaar"
)


def stage(overlay: Path, destination: Path) -> list[str]:
    if destination.name != "shaar" or destination.parent.name != "panels":
        raise SystemExit(f"Refusing to stage outside panels/shaar: {destination}")
    if destination.is_symlink() or (destination.exists() and not destination.is_dir()):
        raise SystemExit(f"Refusing to stage into destination symlink or non-directory: {destination}")
    if overlay.is_symlink() or not overlay.is_dir():
        raise SystemExit(f"Missing overlay: {overlay}")
    destination.mkdir(parents=True, exist_ok=True)
    staged = []
    for source in sorted(overlay.rglob("*")):
        if source.is_symlink():
            raise SystemExit(f"Refusing to stage overlay symlink: {source.relative_to(overlay)}")
        if not source.is_file():
            continue
        relative = source.relative_to(overlay)
        target = destination / relative
        parent = destination
        for component in relative.parts[:-1]:
            parent = parent / component
            if parent.is_symlink():
                raise SystemExit(f"Refusing destination symlink: {parent}")
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() or target.is_symlink():
            target.unlink()
        try:
            os.link(source, target)
        except OSError:
            shutil.copy2(source, target)
        staged.append(relative.as_posix())
    return staged


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--overlay", type=Path, default=OVERLAY)
    options = parser.parse_args()
    staged = stage(options.overlay, options.destination)
    for name in staged:
        print(name)


if __name__ == "__main__":
    main()
