#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Run Python test files in each direct child test directory under Tests."""

from __future__ import annotations

import argparse
import importlib.util
import sys
import time
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
TESTS_ROOT = REPOSITORY_ROOT / "Tests"


class ReportResult(unittest.TextTestResult):
    """Record per-test JUnit results, including failures in unittest subtests."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.report = ET.Element("testsuite", name="Python")
        self.cases = {}
        self.started = {}

    def startTest(self, test):
        super().startTest(test)
        self.started[test] = time.monotonic()
        self.case_for(test)

    def case_for(self, test):
        parent = getattr(test, "test_case", test)
        if parent not in self.cases:
            self.cases[parent] = ET.SubElement(self.report, "testcase", name=parent.id())
        return self.cases[parent]

    def stopTest(self, test):
        self.cases[test].set("time", str(time.monotonic() - self.started[test]))
        super().stopTest(test)

    def addFailure(self, test, err):
        super().addFailure(test, err)
        ET.SubElement(self.case_for(test), "failure").text = self._exc_info_to_string(err, test)

    def addError(self, test, err):
        super().addError(test, err)
        ET.SubElement(self.case_for(test), "error").text = self._exc_info_to_string(err, test)

    def addSkip(self, test, reason):
        super().addSkip(test, reason)
        ET.SubElement(self.case_for(test), "skipped", message=reason)

    def addSubTest(self, test, subtest, err):
        super().addSubTest(test, subtest, err)
        if err is not None:
            ET.SubElement(self.cases[test], "failure", message=str(subtest)).text = self._exc_info_to_string(err, test)

    def addExpectedFailure(self, test, err):
        super().addExpectedFailure(test, err)
        ET.SubElement(self.cases[test], "skipped", message="Expected failure")

    def addUnexpectedSuccess(self, test):
        super().addUnexpectedSuccess(test)
        ET.SubElement(self.cases[test], "failure", message="Unexpected success")

    def write_report(self, path):
        self.report.set("tests", str(len(self.report)))
        self.report.set("failures", str(len(self.failures) + len(self.unexpectedSuccesses)))
        self.report.set("errors", str(len(self.errors)))
        self.report.set("skipped", str(len(self.skipped) + len(self.expectedFailures)))
        path.parent.mkdir(parents=True, exist_ok=True)
        ET.ElementTree(self.report).write(path, encoding="utf-8", xml_declaration=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--junit", type=Path)
    options = parser.parse_args()
    sys.path.insert(0, str(REPOSITORY_ROOT))
    test_directories = sorted(path for path in TESTS_ROOT.iterdir() if path.is_dir())
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()
    discovered_files = 0

    for test_directory in test_directories:
        test_files = sorted(test_directory.glob("test_*.py"))
        if not test_files:
            continue
        discovered_files += len(test_files)
        for test_file in test_files:
            module_spec = importlib.util.spec_from_file_location(test_file.stem, test_file)
            if module_spec is None or module_spec.loader is None:
                print(f"Could not load Python test module: {test_file}", file=sys.stderr)
                return 1
            module = importlib.util.module_from_spec(module_spec)
            sys.modules[module_spec.name] = module
            module_spec.loader.exec_module(module)
            suite.addTests(loader.loadTestsFromModule(module))

    test_count = suite.countTestCases()
    if discovered_files == 0 or test_count == 0:
        print(f"No Python tests discovered under {TESTS_ROOT}", file=sys.stderr)
        return 1

    result = unittest.TextTestRunner(verbosity=2, resultclass=ReportResult).run(suite)
    if options.junit:
        result.write_report(options.junit)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
