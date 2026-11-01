#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Fail the stable required check on failed, cancelled or unexpectedly skipped stages."""

import json
import os
from pathlib import Path


def gate_errors(needs: dict, full: bool, nightly: bool) -> list[str]:
    expected = {"plan", "fast", "dependency-review"}
    native = {"build", "coverage", "visuals", "engine", "shipping", "codeql"}
    if full:
        expected |= native
    if nightly:
        expected |= {"sanitizers", "dead-code"}
    optional = (native | {"sanitizers", "dead-code"}) - expected
    errors = [f"{name}: {needs.get(name, {}).get('result', 'missing')}"
              for name in sorted(expected) if needs.get(name, {}).get("result") != "success"]
    errors += [f"{name}: {item.get('result', 'missing')}"
               for name, item in needs.items()
               if name in optional and item.get("result") not in ("success", "skipped")]
    return errors


def main() -> int:
    needs = json.loads(os.environ["CI_NEEDS"])
    errors = gate_errors(needs, os.environ["CI_FULL"] == "true", os.environ["CI_NIGHTLY"] == "true")
    with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as output:
        output.write("### CI required\n\n| Stage | Result |\n| --- | --- |\n")
        for name, item in sorted(needs.items()):
            output.write(f"| {name} | {item['result']} |\n")
        output.write("\n" + ("\n".join(errors) if errors else "All selected stages passed.") + "\n")
    for error in errors:
        print(error)
    return int(bool(errors))


if __name__ == "__main__":
    raise SystemExit(main())
