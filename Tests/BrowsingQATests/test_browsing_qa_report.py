# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from contextlib import redirect_stderr
from datetime import datetime, timezone
import io
import importlib.util
import re
import shutil
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "browsing_qa", ROOT / "scripts/test-browsing-qa.py")
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)

GIBIBYTE = 1024 ** 3


class BrowsingQAReportTests(unittest.TestCase):
    def test_main_rejects_colliding_report_paths_before_app_validation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            receipt = root / "report.json"
            with patch.object(sys, "argv", [
                "test-browsing-qa.py", "--app", str(root / "missing.app"),
                "--receipt", str(receipt), "--markdown", str(root / "nested" / ".." / "report.json"),
            ]), patch.object(PROBE, "run_suite") as run_suite:
                errors = io.StringIO()
                with redirect_stderr(errors), self.assertRaises(SystemExit) as exit_error:
                    PROBE.main()
            self.assertEqual(exit_error.exception.code, 2)
            self.assertIn("receipt and markdown output paths must differ", errors.getvalue())
            run_suite.assert_not_called()

    def test_receipt_and_markdown_outputs_must_not_resolve_to_the_same_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            receipt = root / "reports" / "receipt.json"
            receipt.parent.mkdir()
            (receipt.parent / "unused").mkdir()
            receipt.write_text("preserve this", encoding="utf-8")
            markdown = root / "reports" / "unused" / ".." / "receipt.json"

            with self.assertRaisesRegex(ValueError, "receipt and markdown output paths must differ"):
                PROBE.write_receipt(receipt, markdown, root / "ShaarVerification", [])

            self.assertEqual(receipt.read_text(encoding="utf-8"), "preserve this")

    def test_slow_reload_fixture_numbers_requests_per_run_path(self):
        original = PROBE.Fixture.slow_reload_requests
        PROBE.Fixture.slow_reload_requests = {}
        try:
            self.assertEqual(PROBE.Fixture.next_slow_reload_request("/run-a"), 1)
            self.assertEqual(PROBE.Fixture.next_slow_reload_request("/run-a"), 2)
            self.assertEqual(PROBE.Fixture.next_slow_reload_request("/run-b"), 1)
        finally:
            PROBE.Fixture.slow_reload_requests = original

    def test_receipt_and_markdown_paths_must_not_collide_or_follow_symlinks(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shared = root / "report.json"
            shared.write_text("preserve this", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "receipt and markdown output paths must differ"):
                PROBE.write_receipt(shared, shared, root / "app", [])
            self.assertEqual(shared.read_text(encoding="utf-8"), "preserve this")

            target = root / "outside.json"
            target.write_text("preserve target", encoding="utf-8")
            receipt = root / "receipt.json"
            receipt.symlink_to(target)
            with self.assertRaisesRegex(ValueError, "output path must not be a symlink"):
                PROBE.write_receipt(receipt, root / "table.md", root / "app", [])
            self.assertEqual(target.read_text(encoding="utf-8"), "preserve target")

    def test_heavy_scroll_requires_page_event_before_attributing_no_growth(self):
        fixture = (ROOT / "scripts/test-browsing-qa.py").read_text()
        source = (ROOT / "Sources/ShaarVerification/ShaarBrowsingQA.swift").read_text()
        self.assertIn("window.__scrollEvents=0", fixture)
        self.assertIn("window.__scrollEvents++", fixture)
        self.assertIn('script: "window.__scrollEvents||0"', source)
        self.assertIn('row(\n        "heavy-scroll", "blocked",', source)

    def test_fifty_tabs_always_run(self):
        allowed, reason = PROBE.allow_overload(50, None, None, None)
        self.assertTrue(allowed)
        self.assertEqual(reason, "")

    def test_larger_run_needs_a_prior_sample(self):
        allowed, reason = PROBE.allow_overload(100, None, None, 20 * GIBIBYTE)
        self.assertFalse(allowed)
        self.assertIn("no memory sample", reason)

    def test_larger_run_needs_a_memory_reading(self):
        allowed, reason = PROBE.allow_overload(100, 50, GIBIBYTE, None)
        self.assertFalse(allowed)
        self.assertIn("available memory", reason)

    def test_projected_rss_above_eight_gibibytes_is_refused(self):
        allowed, reason = PROBE.allow_overload(200, 100, 5 * GIBIBYTE, 64 * GIBIBYTE)
        self.assertFalse(allowed)
        self.assertIn("8 GiB", reason)

    def test_projected_rss_plus_headroom_must_fit(self):
        allowed, _reason = PROBE.allow_overload(100, 50, 3 * GIBIBYTE, 6 * GIBIBYTE)
        self.assertFalse(allowed)
        allowed, _reason = PROBE.allow_overload(100, 50, GIBIBYTE, 20 * GIBIBYTE)
        self.assertTrue(allowed)

    def test_earlier_sample_is_the_largest_smaller_count(self):
        self.assertEqual(PROBE.earlier_overload(200, {50: 10, 100: 20}), (100, 20))
        self.assertIsNone(PROBE.earlier_overload(50, {100: 20}))

    def test_unknown_scenario_is_rejected(self):
        with self.assertRaises(PROBE.UnknownScenario):
            PROBE.parse_scenarios("overload-50,not-a-scenario")
        self.assertEqual(PROBE.parse_scenarios(""), list(PROBE.DEFAULT_SCENARIOS))

    def test_hang_and_failed_rows_outrank_a_clean_exit(self):
        self.assertEqual(PROBE.scenario_result({}, None, True, []), "hang")
        report = {"passed": False, "rows": [{"status": "fail"}]}
        self.assertEqual(PROBE.scenario_result(report, 0, False, []), "fail")
        blocked = {"passed": True, "rows": [{"status": "blocked"}]}
        self.assertEqual(PROBE.scenario_result(blocked, 0, False, []), "blocked")
        passed = {"passed": True, "rows": [{"status": "pass"}, {"status": "blocked"}]}
        self.assertEqual(PROBE.scenario_result(passed, 0, False, []), "pass")
        empty = {"passed": True, "rows": []}
        self.assertEqual(PROBE.scenario_result(empty, 0, False, []), "fail")
        unknown = {"passed": True, "rows": [{"status": "skipped"}]}
        self.assertEqual(PROBE.scenario_result(unknown, 0, False, []), "fail")
        malformed = {"passed": True, "rows": [None]}
        self.assertEqual(PROBE.scenario_result(malformed, 0, False, []), "fail")

    def test_malformed_rows_fail_the_scenario_without_crashing(self):
        report = {"passed": True, "rows": [None]}
        self.assertEqual(PROBE.scenario_result(report, 0, False, []), "fail")

    def test_malformed_rows_fail_the_scenario_without_crashing(self):
        report = {"passed": True, "rows": [None]}
        self.assertEqual(PROBE.scenario_result(report, 0, False, []), "fail")

    def test_unknown_or_missing_row_status_cannot_pass_the_scenario(self):
        for row in ({"status": "unknown"}, {}, {"status": ["pass"]}):
            with self.subTest(row=row):
                report = {"passed": True, "rows": [row]}
                self.assertEqual(PROBE.scenario_result(report, 0, False, []), "fail")

    def test_unhashable_row_status_does_not_crash_note_formatting(self):
        notes = PROBE.row_notes({"rows": [{"status": ["fail"]}]}, "")
        self.assertEqual(notes, "")

    def test_deliberate_renderer_kill_matches_pid_and_time(self):
        finished = datetime(2026, 11, 10, 12, 0, 30, tzinfo=timezone.utc)
        report = {"rows": [
            {
                "name": "renderer-kill",
                "status": "pass",
                "signaledPIDs": [42],
                "signaledAt": "2026-11-10T12:00:05+00:00",
            },
            {"name": "renderer-recover", "status": "pass"},
        ]}
        match = '{"pid" : 42, "captureTime" : "2026-11-10 07:00:10.0000 -0500"}'
        self.assertFalse(PROBE.crash_counts_against_suite("renderer", report, match, finished))
        other_pid = '{"pid" : 99, "captureTime" : "2026-11-10 07:00:10.0000 -0500"}'
        self.assertTrue(PROBE.crash_counts_against_suite("renderer", report, other_pid, finished))
        too_late = '{"pid" : 42, "captureTime" : "2026-11-10 07:02:00.0000 -0500"}'
        self.assertTrue(PROBE.crash_counts_against_suite("renderer", report, too_late, finished))
        text_only = "EXC_CRASH SIGKILL"
        self.assertTrue(PROBE.crash_counts_against_suite("renderer", report, text_only, finished))
        self.assertTrue(PROBE.crash_counts_against_suite("windows", report, match, finished))

    def test_make_clip_timeout_returns_no_bytes(self):
        def expired(*_args, **_kwargs):
            raise subprocess.TimeoutExpired(cmd="ffmpeg", timeout=30)

        original_which = PROBE.shutil.which
        original_run = PROBE.subprocess.run
        PROBE.shutil.which = lambda name: "/usr/bin/ffmpeg" if name == "ffmpeg" else None
        PROBE.subprocess.run = expired
        try:
            self.assertEqual(PROBE.make_clip(Path("/tmp")), b"")
        finally:
            PROBE.shutil.which = original_which
            PROBE.subprocess.run = original_run

    def test_suite_passes_when_every_scenario_is_pass_or_blocked(self):
        self.assertTrue(PROBE.suite_passed([
            {"scenario": "dialogs", "result": "pass"},
            {"scenario": "heavy", "result": "blocked"},
        ]))
        self.assertFalse(PROBE.suite_passed([{"result": "pass"}, {"result": "hang"}]))
        self.assertFalse(PROBE.suite_passed([
            {"scenario": "overload-50", "result": "pass"},
            {"scenario": "overload-100", "result": "blocked"},
        ]))

    def test_markdown_table_names_the_scenario_and_escapes_notes(self):
        table = PROBE.markdown_table([{
            "scenario": "windows",
            "result": "fail",
            "seconds": 12.2,
            "peakRSSBytes": 1024 * 1024,
            "crashes": [],
            "notes": "drop | rejected",
        }])
        self.assertIn("| windows | fail | 12 | 1 MiB | none | drop / rejected |", table)
        self.assertTrue(table.startswith("| Scenario |"))

    def test_scroll_fixture_appends_rows_only_after_scroll_and_stops_at_200(self):
        node = shutil.which("node")
        if node is None:
            self.skipTest("Node.js is required to execute the fixture script")

        fixture = PROBE.Fixture.document(None, "/scroll", "").decode()
        match = re.search(r"<script>(.*?)</script>", fixture, re.DOTALL)
        self.assertIsNotNone(match)
        runner = r"""
const assert = require('node:assert/strict');
const vm = require('node:vm');
let source = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => source += chunk);
process.stdin.on('end', () => {
  const feed = {
    children: [], listeners: {},
    appendChild(row) { this.children.push(row); },
    addEventListener(name, callback) { this.listeners[name] = callback; },
  };
  const document = {
    getElementById(id) { assert.equal(id, 'feed'); return feed; },
    createElement(tag) { assert.equal(tag, 'div'); return {textContent: ''}; },
  };
  const page = {document};
  page.window = page;
  vm.runInNewContext(source, page);
  assert.equal(feed.children.length, 100, 'initial rows');
  feed.listeners.scroll();
  assert.equal(feed.children.length, 200, 'rows after first scroll');
  feed.listeners.scroll();
  assert.equal(feed.children.length, 200, 'row cap after later scroll');
});
"""
        completed = subprocess.run(
            [node, "-e", runner], input=match.group(1), text=True,
            capture_output=True, timeout=10, check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_malformed_rows_are_reported_without_crashing_note_formatting(self):
        notes = PROBE.row_notes({"rows": [None]}, "")
        self.assertIn("malformed scenario row", notes.lower())

    def test_malformed_status_scalar_fails_without_crashing_report_formatting(self):
        report = {"passed": True, "rows": [{"status": []}]}
        self.assertEqual(PROBE.scenario_result(report, 0, False, []), "fail")
        notes = PROBE.row_notes(report, "")
        self.assertIn("malformed scenario row status", notes.lower())

    def test_malformed_renderer_rows_cannot_hide_a_crash(self):
        finished = datetime(2026, 11, 10, 12, 0, 30, tzinfo=timezone.utc)
        report = {"rows": [None]}
        self.assertTrue(
            PROBE.crash_counts_against_suite("renderer", report, "EXC_CRASH", finished))
        self.assertFalse(PROBE.deliberate_renderer_kill(report, "EXC_CRASH", finished))
if __name__ == "__main__":
    unittest.main()
