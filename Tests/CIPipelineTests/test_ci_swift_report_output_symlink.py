# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location(
    "ci_swift_reports", ROOT / "scripts/ci-swift-reports.py")
REPORTS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORTS)


class CISwiftReportOutputSymlinkTests(unittest.TestCase):
    def test_xctest_report_rejects_symlink_without_overwriting_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            log = directory / "tests.log"
            log.write_text(
                "Test Suite 'All tests' started at now.\n"
                "Test Case 'Fixture.sample' started.\n"
                "Test Case 'Fixture.sample' passed (0.125 seconds).\n"
                "Test Suite 'All tests' passed at now.\n"
                "Executed 1 test, with 0 failures in 0.125 seconds\n"
            )
            external = directory / "external.xml"
            external.write_text("preserve this report")
            (directory / "xctest.xml").symlink_to(external)

            with self.assertRaisesRegex(ValueError, "CI evidence output must not be a symlink"):
                REPORTS.write_reports(log, directory)

            self.assertEqual(external.read_text(), "preserve this report")
            self.assertFalse((directory / "swift.xml").exists())


if __name__ == "__main__":
    unittest.main()
