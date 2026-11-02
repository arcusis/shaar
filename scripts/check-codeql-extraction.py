#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Reject a successful Swift analysis that omitted a tracked source file."""

import argparse
import json
import os
from pathlib import Path
from urllib.parse import unquote, urlparse

from ci_support import swift_source_files


ROOT = Path(__file__).resolve().parents[1]


def extracted_paths(document: dict, root: Path) -> set[str]:
    paths = set()
    rows = document["#select"]["tuples"]
    if not isinstance(rows, list):
        raise ValueError("Extracted-file report has no tuples")
    for row in rows:
        entity = row[0]
        label = entity["label"]
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--scope", choices=("full", "shipping"), default="full")
    options = parser.parse_args()
    expected = swift_source_files(ROOT, options.scope, tracked=False,
                                  include_build_inputs=options.scope == "full")
    missing = missing_sources(json.loads(options.report.read_text()), expected, ROOT)
    result = {"scope": options.scope, "expected": len(expected), "missing": missing, "revision": os.environ.get("GITHUB_SHA", "local")}
    options.report.with_name("coverage.json").write_text(json.dumps(result, indent=2) + "\n")
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
