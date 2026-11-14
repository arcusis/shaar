#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Fail the stable required check on failed, cancelled or unexpectedly skipped stages."""

import json
import os
from pathlib import Path
import sys

from ci_support import output_file


def advisory_stages(raw: str | None) -> set[str]:
    """Stages named in the CI_ADVISORY_STAGES repository variable report but do not block."""
    return {name.strip() for name in (raw or "").split(",") if name.strip()}


def parse_needs(raw: str) -> dict:
    """Parse the GitHub needs context and reject malformed stage results clearly."""
    try:
        needs = json.loads(raw)
    except json.JSONDecodeError as error:
        raise ValueError(f"CI_NEEDS is not valid JSON: {error.msg}") from error
    if not isinstance(needs, dict):
        raise ValueError("CI_NEEDS must be a JSON object mapping stages to results")
    for name, item in needs.items():
        if not isinstance(item, dict) or not isinstance(item.get("result"), str):
            raise ValueError(f"CI_NEEDS entry {name!r} must contain a string result")
    return needs


def gate_errors(needs: dict, full: bool, nightly: bool, website: bool = False,
                browsing: bool = False, shipping_guard: bool = False,
                advisory: set[str] | None = None) -> list[str]:
    expected = {"plan", "fast", "dependency-review", "codeql"}
    native = {
        "python-tests", "build", "coverage", "visuals", "localization", "localization-captures",
        "engine", "shaar-engine-simulation", "shipping", "inspector-contracts",
    }
    if full:
        expected |= native
    if browsing:
        expected.add("basic-browsing")
    if website:
        expected.add("website")
    if shipping_guard:
        expected.add("shipping-probe-guard")
    if nightly:
        expected |= {"sanitizers", "dead-code"}
    optional = (native | {"basic-browsing", "sanitizers", "dead-code", "website",
                          "shipping-probe-guard"}) - expected
    advisory = (advisory or set()) - {"plan", "fast", "dependency-review", "codeql", "build"}
    errors = [f"{name}: {needs.get(name, {}).get('result', 'missing')}"
              for name in sorted(expected - advisory) if needs.get(name, {}).get("result") != "success"]
    errors += [f"{name}: {item.get('result', 'missing')}"
               for name, item in needs.items()
               if name in optional - advisory and item.get("result") not in ("success", "skipped")]
    known = expected | optional
    errors += [f"{name}: not classified by CI required gate"
               for name in sorted(needs) if name not in known]
    return errors


def main() -> int:
    required = ("CI_NEEDS", "CI_FULL", "CI_NIGHTLY", "GITHUB_STEP_SUMMARY")
    missing = next((name for name in required if not os.environ.get(name)), None)
    if missing:
        print(f"CI required gate: missing or empty environment variable {missing}", file=sys.stderr)
        return 2

    for name in ("CI_FULL", "CI_NIGHTLY", "CI_WEBSITE", "CI_BROWSING", "CI_SHIPPING_GUARD"):
        value = os.environ.get(name)
        if value is not None and value not in ("true", "false"):
            print(f"CI required gate: {name} must be 'true' or 'false'", file=sys.stderr)
            return 2

    needs = parse_needs(os.environ["CI_NEEDS"])
    errors = gate_errors(needs, os.environ["CI_FULL"] == "true", os.environ["CI_NIGHTLY"] == "true",
                         os.environ.get("CI_WEBSITE") == "true",
                         os.environ.get("CI_BROWSING") == "true",
                         os.environ.get("CI_SHIPPING_GUARD") == "true",
                         advisory_stages(os.environ.get("CI_ADVISORY_STAGES")))
    with output_file(Path(os.environ["GITHUB_STEP_SUMMARY"])).open("a") as output:
        output.write("### CI required\n\n| Stage | Result |\n| --- | --- |\n")
        for name, item in sorted(needs.items()):
            output.write(f"| {name} | {item['result']} |\n")
        advisory = advisory_stages(os.environ.get("CI_ADVISORY_STAGES"))
        if advisory:
            output.write("\nAdvisory (reported, not blocking): " + ", ".join(sorted(advisory)) + "\n")
        output.write("\n" + ("\n".join(errors) if errors else "All selected stages passed.") + "\n")
    for error in errors:
        print(error)
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
