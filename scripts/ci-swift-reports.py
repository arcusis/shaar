#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Retain native Swift Testing XML and report serial XCTest events as JUnit."""

import argparse
from pathlib import Path
import re
import xml.etree.ElementTree as ET


CASE_EVENT = re.compile(r"^Test Case '(.+)' (started|passed|failed|skipped)(?: \(([0-9.]+) seconds\))?\.$")
SUITE_END = re.compile(r"^Test Suite '(?:All tests|Selected tests)' (?:passed|failed) at ")
TOTAL = re.compile(r"^\s*Executed ([0-9]+) tests?\b")


def case_identity(label: str) -> tuple[str, str]:
    if label.startswith("-[") and label.endswith("]"):
        return tuple(label[2:-1].split(" ", 1))
    parts = label.rsplit(".", 1)
    return tuple(parts) if len(parts) == 2 else ("XCTest", label)


def xctest_cases(text: str) -> list[ET.Element]:
    active = {}
    cases = []
    totals = []
    awaiting_total = False
    for line in text.splitlines():
        event = CASE_EVENT.match(line)
        if event:
            label, state, seconds = event.groups()
            if state == "started":
                if label in active:
                    raise ValueError(f"Duplicate XCTest start: {label}")
                classname, name = case_identity(label)
                active[label] = (ET.Element("testcase", classname=classname, name=name), [])
            else:
                if label not in active or seconds is None:
                    raise ValueError(f"Unpaired or untimed XCTest end: {label}")
                case, details = active.pop(label)
                float(seconds)
                case.set("time", seconds)
                if state in ("failed", "skipped"):
                    tag = "failure" if state == "failed" else "skipped"
                    ET.SubElement(case, tag, message=f"XCTest {state}").text = "\n".join(details)
                cases.append(case)
        elif SUITE_END.match(line):
            awaiting_total = True
        elif awaiting_total and (total := TOTAL.match(line)):
            totals.append(int(total.group(1)))
            awaiting_total = False
        else:
            for _, details in active.values():
                details.append(line)
    if active or awaiting_total or not totals or sum(totals) != len(cases):
        raise ValueError("XCTest log is incomplete or its outer-suite totals do not match cases")
    return cases


def write_reports(log: Path, directory: Path) -> None:
    text = log.read_text()
    cases = xctest_cases(text)
    native = sorted(directory.glob("swift*-swift-testing.xml"))
    if "Test run with " in text and not native:
        raise ValueError("Swift Testing ran without producing its native JUnit XML")
    for report in native:
        ET.parse(report)
    failures = sum(case.find("failure") is not None for case in cases)
    skipped = sum(case.find("skipped") is not None for case in cases)
    suite = ET.Element("testsuite", name="XCTest", tests=str(len(cases)),
                       failures=str(failures), errors="0", skipped=str(skipped))
    suite.extend(cases)
    ET.ElementTree(suite).write(directory / "xctest.xml", encoding="utf-8", xml_declaration=True)
    # Some toolchains also emit XCTest XML here. The validated conversion owns
    # that provider's report, so retain one copy of each test rather than two.
    (directory / "swift.xml").unlink(missing_ok=True)
    print(f"XCTest JUnit: {len(cases)} tests, {failures} failures, {skipped} skipped; "
          f"native Swift Testing reports: {len(native)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--directory", type=Path, required=True)
    options = parser.parse_args()
    write_reports(options.log, options.directory)


if __name__ == "__main__":
    main()
