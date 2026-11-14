#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Reject a successful Swift analysis that omitted a tracked source file."""

import argparse
import json
import os
from pathlib import Path
import sys
from urllib.parse import unquote, urlparse

from ci_support import swift_source_files


ROOT = Path(__file__).resolve().parents[1]


def extracted_paths(document: dict, root: Path) -> set[str]:
    paths = set()
    selection = document.get("#select") if isinstance(document, dict) else None
    rows = selection.get("tuples") if isinstance(selection, dict) else None
    if not isinstance(rows, list):
        raise ValueError("Extracted-file report has no tuples")
    for index, row in enumerate(rows):
        if not isinstance(row, list) or not row or not isinstance(row[0], dict):
            raise ValueError(f"Extracted-file tuple {index} is malformed")
        entity = row[0]
        label = entity.get("label")
        if not isinstance(label, str):
            raise ValueError(f"Extracted-file tuple {index} has no string label")
        location = entity.get("url", {})
        candidates = [label, location.get("uri", "") if isinstance(location, dict) else location]
        for candidate in candidates:
            if not isinstance(candidate, str) or not candidate:
                continue
            parsed = urlparse(candidate)
            path = Path(unquote(parsed.path) if parsed.scheme == "file" else candidate)
            if path.is_absolute():
                try:
                    path = path.relative_to(root)
                except ValueError:
                    continue
            paths.add(path.as_posix())
    return paths


def missing_sources(document: dict, expected: set[str], root: Path) -> list[str]:
    if not expected:
        raise ValueError("No tracked Swift sources found")
    return sorted(expected - extracted_paths(document, root))


def write_coverage_report(report_path: Path, result: dict) -> None:
    output = report_path.with_name("coverage.json")
    if output.parent.is_symlink():
        raise ValueError(f"coverage output directory must not be a symlink: {output.parent}")
    if output.resolve() == report_path.resolve():
        raise ValueError("extraction input and coverage output paths must differ")
    if output.is_symlink():
        raise ValueError(f"coverage output path must not be a symlink: {output}")
    if output.exists() and not output.is_file():
        raise ValueError(f"coverage output path is not a regular file: {output}")
    output.write_text(json.dumps(result, indent=2) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--scope", choices=("full", "shipping"), default="full")
    options = parser.parse_args()
    expected = swift_source_files(ROOT, options.scope, tracked=False,
                                  include_build_inputs=options.scope == "full")
    try:
        document = json.loads(options.report.read_text(encoding="utf-8"))
        missing = missing_sources(document, expected, ROOT)
        result = {"scope": options.scope, "expected": len(expected), "missing": missing,
                  "revision": os.environ.get("GITHUB_SHA", "local")}
        write_coverage_report(options.report, result)
    except (OSError, UnicodeError, ValueError) as error:
        print(f"Invalid CodeQL extraction report: {error}", file=sys.stderr)
        return 2
    message = f"Swift CodeQL ({options.scope}): {len(expected) - len(missing)}/{len(expected)} tracked source files extracted"
    print(message)
    for name in missing:
        print(f"Missing extraction: {name}")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as output:
            output.write(f"### Swift extraction coverage\n\n{message}.\n")
    return int(bool(missing))


if __name__ == "__main__":
    raise SystemExit(main())
