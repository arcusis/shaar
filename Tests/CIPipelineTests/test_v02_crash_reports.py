# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
import os
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "v02_crash_reports", ROOT / "scripts/v02_crash_reports.py")
CRASH_REPORTS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CRASH_REPORTS)


class V02CrashReportSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "DiagnosticReports"
        (self.root / "Retired" / "Nested").mkdir(parents=True)

    def write_report(self, relative, mtime_ns=1_800_000_000_000_000_000):
        path = self.root / Path(relative)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("report")
        os.utime(path, ns=(mtime_ns, mtime_ns))
        return path

    def test_snapshot_recurses_and_matches_every_bundled_process_name(self):
        names = (
            "ShaarVerification-2026-11-15-142116.ips",
            "ArcusisBrowser-2026-11-15-142116.crash",
            "Shaar-2026-11-15-142116.ips",
            "Chromium Helper (Renderer)-2026-11-15-142116.ips",
            "chrome_crashpad_handler-2026-11-15-142116.crash",
        )
        for index, name in enumerate(names):
            relative = Path("Retired/Nested") / name if index % 2 else Path(name)
            self.write_report(relative, 1_800_000_000_000_000_000 + index)
        self.write_report("Retired/Nested/OtherApp-2026-11-15.ips")
        self.write_report("Retired/Nested/ShaarVerification-not-a-crash.txt")

        result = CRASH_REPORTS.snapshot(self.root)["reports"]

        self.assertEqual(len(result), len(names))
        self.assertEqual(
            result["Retired/Nested/Chromium Helper (Renderer)-2026-11-15-142116.ips"]["mtime_ns"],
            1_800_000_000_000_000_003,
        )

    def test_delta_detects_new_and_modified_reports_recursively(self):
        old = self.write_report("ShaarVerification-old.ips", 1_800_000_000_000_000_000)
        before = CRASH_REPORTS.snapshot(self.root)
        self.write_report("Retired/Nested/Chromium Helper (GPU)-new.crash",
                          1_800_000_000_000_000_001)
        old.write_text("updated report")
        os.utime(old, ns=(1_800_000_000_000_000_002, 1_800_000_000_000_000_002))
        after = CRASH_REPORTS.snapshot(self.root)

        reports = CRASH_REPORTS.new_reports(before, after)

        self.assertEqual(
            {item["name"] for item in reports},
            {"ShaarVerification-old.ips", "Chromium Helper (GPU)-new.crash"},
        )

    def test_moving_existing_report_into_retired_is_not_a_new_crash(self):
        report = self.write_report("ShaarVerification-older.ips")
        before = CRASH_REPORTS.snapshot(self.root)
        destination = self.root / "Retired" / report.name
        report.rename(destination)
        after = CRASH_REPORTS.snapshot(self.root)

        self.assertEqual(CRASH_REPORTS.new_reports(before, after), [])


if __name__ == "__main__":
    unittest.main()
