# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep native localization crash evidence attached to a failed CI run."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "localization_fixture", ROOT / "scripts/localization-fixture.py"
)
with patch.object(sys, "path", [str(ROOT / "scripts"), *sys.path]):
    FIXTURE = importlib.util.module_from_spec(SPEC)
    SPEC.loader.exec_module(FIXTURE)


class LocalizationCrashEvidenceTests(unittest.TestCase):
    def test_failed_probe_keeps_owned_crashpad_dump(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile = root / "profile"
            profile.mkdir()
            (profile / FIXTURE.MARKER).write_text(
                "arcusis-localization-probe-v1\n", encoding="utf-8"
            )
            crashpad = profile / "Chromium" / "Crashpad" / "completed"
            crashpad.mkdir(parents=True)
            (crashpad / "owned.dmp").write_bytes(b"owned crash")
            outside = root / "outside.dmp"
            outside.write_bytes(b"other process")
            (crashpad / "outside.dmp").symlink_to(outside)
            completed = subprocess.CompletedProcess([], -11, "", "")
            with (
                patch.object(FIXTURE.engine_fixture, "crash_reports_for", return_value=[]),
                patch.object(FIXTURE.engine_fixture, "wait_until", return_value=0),
            ):
                FIXTURE.record_failed_probe(
                    "english-restart", profile / "probe.json", completed,
                    4242, time.time() - 1, root / "artifact",
                )
            artifact = root / "artifact"
            receipt = json.loads((artifact / "english-restart-failure.json").read_text())
            self.assertEqual(receipt["crashpadDumps"], ["owned.dmp"])
            self.assertEqual(
                (artifact / "english-restart-crashpad-1.dmp").read_bytes(), b"owned crash"
            )

    def test_backtrace_setting_reaches_only_the_verification_child(self):
        with patch.dict(FIXTURE.os.environ, {
            "PATH": "/usr/bin", "SWIFT_BACKTRACE": "enable=no",
            "SHAAR_LOCALIZATION_BACKTRACE": "1",
        }, clear=True):
            environment = FIXTURE.safe_environment()
            self.assertNotIn("SWIFT_BACKTRACE", environment)
            with patch.object(FIXTURE.subprocess, "Popen") as launch:
                launch.return_value.pid = 123
                launch.return_value.returncode = 0
                launch.return_value.communicate.return_value = ("", "")
                FIXTURE.run_engine_probe(["probe"], environment)
                child_environment = launch.call_args.kwargs["env"]
                self.assertEqual(
                    child_environment["SWIFT_BACKTRACE"], FIXTURE.BACKTRACE_SETTING
                )
                self.assertNotIn("SWIFT_BACKTRACE", environment)

    def test_failed_probe_keeps_its_report_and_matching_crash(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = root / "probe.json"
            report.write_text('{"passed": true}\n', encoding="utf-8")
            crash_name = "ShaarVerification-2026-11-06-120000.ips"
            (root / crash_name).write_text("crash stack", encoding="utf-8")
            completed = subprocess.CompletedProcess([], -11, "", "token sk-abcdefghijklmnop")
            with (
                patch.object(FIXTURE.engine_fixture, "CRASH_REPORT_DIRECTORY", root),
                patch.object(
                    FIXTURE.engine_fixture, "crash_reports_for", return_value=[crash_name]
                ),
                patch.object(FIXTURE.engine_fixture, "wait_until", return_value=0),
            ):
                FIXTURE.record_failed_probe(
                    "hebrew-restart", report, completed, 4242, 100, root / "artifact"
                )
            artifact = root / "artifact"
            receipt = json.loads((artifact / "hebrew-restart-failure.json").read_text())
            self.assertEqual(receipt["exitCode"], -11)
            self.assertEqual(receipt["pid"], 4242)
            self.assertTrue(receipt["probeReportWritten"])
            self.assertNotIn("sk-abcdefghijklmnop", receipt["stderrTail"])
            self.assertNotIn(
                "sk-abcdefghijklmnop",
                (artifact / "hebrew-restart-stderr.log").read_text(),
            )
            self.assertEqual(
                (artifact / "hebrew-restart-probe.json").read_text(), report.read_text()
            )
            self.assertEqual((artifact / "hebrew-restart-crash-1.ips").read_text(), "crash stack")


if __name__ == "__main__":
    unittest.main()
