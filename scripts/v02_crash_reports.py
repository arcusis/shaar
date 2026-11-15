# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Snapshot crash reports emitted by Shaar verification and shipping processes."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys


PROCESS_PREFIXES = (
    "ShaarVerification",
    "ArcusisBrowser",
    "Shaar",
    "Chromium Helper",
    "chrome_crashpad_handler",
)
REPORT_SUFFIXES = {".ips", ".crash"}


def matches_report_name(name: str) -> bool:
    path = Path(name)
    if path.suffix.lower() not in REPORT_SUFFIXES:
        return False
    stem = path.name[: -len(path.suffix)]
    return any(
        stem == prefix or stem.startswith(prefix + "-") or stem.startswith(prefix + " ")
        for prefix in PROCESS_PREFIXES
    )


def snapshot(directory: Path) -> dict:
    """Return matching report names and mtimes, recursively, without following symlinks."""
    if not directory.is_dir():
        raise FileNotFoundError(f"DiagnosticReports directory is unavailable: {directory}")

    reports = {}

    def walk_error(error: OSError) -> None:
        raise error

    for current, _, names in os.walk(directory, onerror=walk_error, followlinks=False):
        folder = Path(current)
        for name in names:
            if not matches_report_name(name):
                continue
            path = folder / name
            if path.is_symlink() or not path.is_file():
                continue
            info = path.stat()
            relative = path.relative_to(directory).as_posix()
            reports[relative] = {
                "name": name,
                "mtime_ns": info.st_mtime_ns,
                "mtime_utc": datetime.fromtimestamp(
                    info.st_mtime, tz=timezone.utc).isoformat(),
                "size": info.st_size,
            }
    return {"schema": 1, "reports": dict(sorted(reports.items()))}


def new_reports(before: dict, after: dict) -> list[dict]:
    """Find reports added or modified since a snapshot; a move to Retired is not new."""
    previous = {
        (entry["name"], entry["mtime_ns"], entry["size"])
        for entry in before.get("reports", {}).values()
    }
    added = []
    for relative, entry in after.get("reports", {}).items():
        identity = (entry["name"], entry["mtime_ns"], entry["size"])
        if identity not in previous:
            added.append({"path": relative, **entry})
    return added


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    snapshot_parser = commands.add_parser("snapshot")
    snapshot_parser.add_argument("directory", type=Path)
    delta_parser = commands.add_parser("delta")
    delta_parser.add_argument("before", type=Path)
    delta_parser.add_argument("after", type=Path)
    args = parser.parse_args(argv)

    try:
        if args.command == "snapshot":
            result = snapshot(args.directory)
            has_new = False
        else:
            before = json.loads(args.before.read_text())
            after = json.loads(args.after.read_text())
            added = new_reports(before, after)
            result = {"newReports": added}
            has_new = bool(added)
        print(json.dumps(result, indent=2, sort_keys=True))
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"crash report scan failed: {error}", file=sys.stderr)
        return 2
    return 1 if has_new else 0


if __name__ == "__main__":
    raise SystemExit(main())
