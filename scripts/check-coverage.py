#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Compare source-module line coverage against an immutable base built by the same job."""

import argparse
import json
from fractions import Fraction
from pathlib import Path


MODULES = ("BrowserCore", "ArcusisBrowser", "ChromiumBridge", "Shaar", "ShaarVerification")


def module_coverage(report: dict) -> dict[str, tuple[int, int]]:
    if report.get("type") != "llvm.coverage.json.export" or not report.get("data"):
        raise ValueError("Missing LLVM coverage data")
    counts = {}
    seen = set()
    for data in report["data"]:
        for file in data["files"]:
            filename = file["filename"]
            for module in MODULES:
                marker = f"/Sources/{module}/"
                if marker not in filename:
                    continue
                identity = (module, filename.split(marker, 1)[1])
                if identity in seen:
                    raise ValueError(f"Duplicate source coverage: {identity}")
                seen.add(identity)
                lines = file["summary"]["lines"]
                covered, count = lines["covered"], lines["count"]
                if type(count) is not int or type(covered) is not int or not 0 <= covered <= count:
                    raise ValueError("Invalid covered/total line counts")
                prior = counts.get(module, (0, 0))
                counts[module] = (prior[0] + covered, prior[1] + count)
    if not all(counts.get(module, (0, 0))[1] for module in ("BrowserCore", "ArcusisBrowser")):
        raise ValueError("Missing core or app source coverage")
    return counts


def regressions(base: dict, candidate: dict) -> list[str]:
    errors = []
    for module, (covered, count) in base.items():
        if count == 0:
            continue
        new_covered, new_count = candidate.get(module, (0, 0))
        if not new_count or Fraction(new_covered, new_count) < Fraction(covered, count):
            errors.append(f"{module}: {covered}/{count} to {new_covered}/{new_count}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    options = parser.parse_args()
    base = module_coverage(json.loads(options.base.read_text()))
    candidate = module_coverage(json.loads(options.candidate.read_text()))
    for module, (covered, count) in candidate.items():
        print(f"{module}: {covered}/{count} lines ({100 * covered / count if count else 0:.3f}%)")
    errors = regressions(base, candidate)
    for error in errors:
        print(f"Coverage regression: {error}")
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
