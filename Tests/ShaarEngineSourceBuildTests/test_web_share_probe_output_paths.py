# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Prevent Web Share probe outputs from following symlink destinations."""

import importlib.util
from pathlib import Path
import signal
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
        self.assertIn("write_screenshot(screenshot, screenshot_data)", source)
        self.assertIn("write_receipt(options.receipt, receipt)", source)
        self.assertIn("process = run_probe(", source)
        self.assertIn("evidence = read_evidence(report)", source)
        self.assertIn("screenshot_data = read_probe_file(source)", source)

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
        class TimedOutProcess:
            pid = 123
            returncode = -signal.SIGKILL

            def __init__(self):
                self.calls = 0

            def communicate(self, timeout=None):
                self.calls += 1
                if self.calls == 1:
                    raise PROBE.subprocess.TimeoutExpired(
                        ["probe"], timeout, stderr=b"partial output")
                return b"", b"picker stalled"

        process = TimedOutProcess()
        with mock.patch.object(PROBE.subprocess, "Popen", return_value=process) as popen, \
                mock.patch.object(PROBE.os, "killpg") as kill_group:
            result = PROBE.run_probe(["probe"], {}, timeout=1)

        self.assertTrue(popen.call_args.kwargs["start_new_session"])
        kill_group.assert_called_once_with(123, signal.SIGKILL)
        self.assertEqual(result.returncode, 124)
        self.assertEqual(result.stderr, "picker stalled")

    def test_probe_start_error_becomes_a_failed_receipt_result(self):
        with mock.patch.object(PROBE.subprocess, "Popen", side_effect=OSError("cannot launch")):
            result = PROBE.run_probe(["probe"], {}, timeout=1)

        self.assertEqual(result.returncode, 126)
        self.assertEqual(result.stderr, "cannot launch")

    def test_probe_completion_preserves_exit_code_and_output(self):
        process = mock.Mock(returncode=7)
        process.communicate.return_value = ("probe output", "probe error")
        with mock.patch.object(PROBE.subprocess, "Popen", return_value=process) as popen:
            result = PROBE.run_probe(["probe"], {}, timeout=1)

        self.assertTrue(popen.call_args.kwargs["start_new_session"])
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout, "probe output")
        self.assertEqual(result.stderr, "probe error")

    def test_partial_report_is_treated_as_missing_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            report = Path(temporary) / "report.json"
            report.write_text('{"passed":')

            self.assertIsNone(PROBE.read_evidence(report))

    def test_report_symlink_is_not_followed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "private.json"
            target.write_text('{"passed": true}')
            report = root / "report.json"
            report.symlink_to(target)

            self.assertIsNone(PROBE.read_evidence(report))
            self.assertEqual(target.read_text(), '{"passed": true}')

    def test_screenshot_source_symlink_is_not_read(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "private.png"
            target.write_bytes(b"private data")
            screenshot = root / "share-sheet.png"
            screenshot.symlink_to(target)

            with self.assertRaises(OSError):
                PROBE.read_probe_file(screenshot)
            self.assertEqual(target.read_bytes(), b"private data")


if __name__ == "__main__":
    unittest.main()
