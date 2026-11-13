# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from pathlib import Path
import os
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from ci_support import Commands


class EmptyJUnitReportTests(unittest.TestCase):
    def test_command_summary_rejects_junit_report_without_test_suites(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            summary = root / "summary.md"
            with patch("ci_support.ROOT", root), patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(summary)}):
                checks = Commands("empty-report")
                (checks.directory / "swift.xml").write_text("<testsuites/>\n")

                self.assertEqual(checks.finish(), 1)
                suite = ET.parse(checks.directory / "commands.xml").getroot()
                self.assertEqual(suite.attrib["failures"], "1")
                self.assertIn("JUnit report contains no test suites", summary.read_text())
