#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Collect only report files from marked, owned synthetic engine probe roots."""

import argparse
import os
import shutil
import tempfile
from pathlib import Path


def owned_probe_root(path: Path) -> bool:
    try:
        return (
            not path.is_symlink()
            and path.resolve().parent == Path(tempfile.gettempdir()).resolve()
            and path.name.startswith("arcusis-engine-probe-")
            and path.stat().st_uid == os.getuid()
            and not (path / ".arcusis-probe").is_symlink()
            and (path / ".arcusis-probe").read_text() == "arcusis-engine-probe-v1\n"
        )
    except OSError:
        return False


def collect(log: Path, destination: Path) -> None:
    for line in log.read_text(errors="replace").splitlines():
        if not line.startswith("Probe evidence: "):
            continue
        root = Path(line.removeprefix("Probe evidence: "))
        if not owned_probe_root(root):
            raise ValueError(f"Refusing foreign probe evidence: {root}")
        output = destination / root.name
        output.mkdir(parents=True, exist_ok=True)
        # Never copy Chromium profiles, cookies, extension stores or arbitrary nested files.
        for file in root.iterdir():
            if (file.is_file() and not file.is_symlink() and file.suffix in (".json", ".log", ".png")
                    and file.stat().st_uid == os.getuid() and file.stat().st_size <= 20_000_000):
                shutil.copyfile(file, output / file.name)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    options = parser.parse_args()
    for log in sorted(options.directory.glob("*.log")):
        collect(log, options.directory / "probes")


if __name__ == "__main__":
    main()
