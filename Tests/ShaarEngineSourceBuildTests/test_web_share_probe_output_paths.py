# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Prevent Web Share probe outputs from following symlink destinations."""

import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/test-web-share.py"
SPEC = importlib.util.spec_from_file_location("web_share_probe", SCRIPT)
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class WebShareProbeOutputPathTests(unittest.TestCase):
    def test_probe_checks_and_uses_the_safe_output_writer(self):
        source = SCRIPT.read_text()
        self.assertIn("validate_output_destination(options.receipt)", source)
        self.assertIn("validate_output_destination(screenshot)", source)
        self.assertIn("copy_screenshot(source, screenshot)", source)
        self.assertIn("write_receipt(options.receipt, receipt)", source)
        self.assertIn("process = run_probe(", source)
        self.assertIn("evidence = read_evidence(report)", source)

    def assert_symlink_output_is_rejected(self, name, data):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "target"
            target.write_bytes(b"preserve this")
            output = root / name
            output.symlink_to(target)

            with self.assertRaises(ValueError):
                PROBE.validate_output_destination(output)
            with self.assertRaises(OSError):
                PROBE.write_output(output, data)

            self.assertEqual(target.read_bytes(), b"preserve this")
            self.assertTrue(output.is_symlink())

    def test_receipt_symlink_is_not_followed(self):
        self.assert_symlink_output_is_rejected("receipt.json", b"{}\n")

    def test_screenshot_symlink_is_not_followed(self):
        self.assert_symlink_output_is_rejected("share-sheet.png", b"image")

    def test_probe_timeout_becomes_a_failed_receipt_result(self):
        timeout = PROBE.subprocess.TimeoutExpired(["probe"], 1, stderr=b"picker stalled")
        with mock.patch.object(PROBE.subprocess, "run", side_effect=timeout):
            result = PROBE.run_probe(["probe"], {}, timeout=1)

        self.assertEqual(result.returncode, 124)
        self.assertEqual(result.stderr, "picker stalled")

    def test_probe_start_error_becomes_a_failed_receipt_result(self):
        with mock.patch.object(PROBE.subprocess, "run", side_effect=OSError("cannot launch")):
            result = PROBE.run_probe(["probe"], {}, timeout=1)

        self.assertEqual(result.returncode, 126)
        self.assertEqual(result.stderr, "cannot launch")

    def test_partial_report_is_treated_as_missing_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            report = Path(temporary) / "report.json"
            report.write_text('{"passed":')

            self.assertIsNone(PROBE.read_evidence(report))


if __name__ == "__main__":
    unittest.main()
