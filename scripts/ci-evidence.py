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


def existing_directory(value: str) -> Path:
    path = Path(value)
    if path.is_symlink() or not path.is_dir():
        raise argparse.ArgumentTypeError(f"directory does not exist or is not a directory: {path}")
    return path


def owned_probe_root(path: Path) -> bool:
    try:
        allowed_parents = {Path(tempfile.gettempdir()).resolve(), Path("/tmp").resolve()}
        runner_temp = os.environ.get("RUNNER_TEMP")
        if runner_temp:
            allowed_parents.add(Path(runner_temp).resolve())
        return (
            not path.is_symlink()
            and path.resolve().parent in allowed_parents
            and path.name.startswith("arcusis-engine-probe-")
            and path.stat().st_uid == os.getuid()
            and not (path / ".arcusis-probe").is_symlink()
            and (path / ".arcusis-probe").read_bytes() == b"arcusis-engine-probe-v1\n"
        )
    except (OSError, UnicodeError):
        return False


def symlinked_parent(path: Path) -> Path | None:
    system_aliases = {Path("/var"): Path("/private/var"),
                      Path("/tmp"): Path("/private/tmp")}
    for parent in path.parents:
        if parent.is_symlink() and system_aliases.get(parent) != parent.resolve():
            return parent
    return None


def collect(log: Path, destination: Path) -> None:
    if destination.is_symlink() or (destination.exists() and not destination.is_dir()):
        raise ValueError("evidence destination is not a regular directory")
    parent = symlinked_parent(destination)
    if parent is not None:
        raise ValueError(f"evidence destination has a symlinked parent: {parent}")
    for line in log.read_text(errors="replace").splitlines():
        if not line.startswith("Probe evidence: "):
            continue
        root = Path(line.removeprefix("Probe evidence: "))
        if not owned_probe_root(root):
            raise ValueError(f"Refusing foreign probe evidence: {root}")
        output = destination / root.name
        if output.is_symlink() or (output.exists() and not output.is_dir()):
            raise ValueError(f"evidence output is not a regular directory: {root.name}")
        output.mkdir(parents=True, exist_ok=True)
        # Never copy Chromium profiles, cookies, extension stores or arbitrary nested files.
        for file in root.iterdir():
            if (file.is_file() and not file.is_symlink() and file.suffix in (".json", ".log", ".png")
                    and file.stat().st_uid == os.getuid() and file.stat().st_size <= 20_000_000):
                destination_file = output / file.name
                if destination_file.is_symlink():
                    raise ValueError(f"evidence output file is a symlink: {root.name}/{file.name}")
                shutil.copyfile(file, destination_file)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=existing_directory, required=True)
    options = parser.parse_args()
    for log in sorted(options.directory.glob("*.log")):
        collect(log, options.directory / "probes")


if __name__ == "__main__":
    main()
