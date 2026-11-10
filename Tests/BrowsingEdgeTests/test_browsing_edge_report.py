# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "browsing_edge", ROOT / "scripts/test-browsing-edge-probe.py")
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class BrowsingEdgeReportTests(unittest.TestCase):
    def test_unproven_row_fails_even_when_marked_passed(self):
        self.assertFalse(PROBE.row_accepted({"passed": True, "proven": False}))

    def test_unproven_failure_is_still_a_failure(self):
        self.assertFalse(PROBE.row_accepted({"passed": False, "proven": False}))

    def test_missing_proven_still_needs_a_pass(self):
        self.assertTrue(PROBE.row_accepted({"passed": True}))
        self.assertFalse(PROBE.row_accepted({"passed": False}))

    def test_empty_report_fails(self):
        self.assertFalse(PROBE.report_passed([]))

    def test_one_bad_row_fails_the_report(self):
        rows = [
            {"passed": True, "proven": True},
            {"passed": True, "proven": False},
        ]
        self.assertFalse(PROBE.report_passed(rows))

    def test_visible_note_fails_a_hidden_windows_row_that_claims_a_pass(self):
        rows = [{"name": "Hidden windows", "passed": True, "proven": True}]
        dialogs = [{"kind": "visible", "title": "Leak"}]
        harness = {"passed": True, "proven": True}
        self.assertFalse(PROBE.visible_notes_fail_their_row(rows, dialogs))
        self.assertFalse(PROBE.evaluate_gate(rows, dialogs, harness))

    def test_visible_note_requires_the_failed_row_the_gate_reads(self):
        rows = [
            {"name": "Find in page", "passed": True, "proven": True},
            {"name": "Hidden windows", "passed": False, "proven": True},
        ]
        dialogs = [{"kind": "visible", "title": "Leak"}]
        harness = {"passed": True, "proven": True}
        self.assertTrue(PROBE.visible_notes_fail_their_row(rows, dialogs))
        self.assertFalse(PROBE.report_passed(rows))
        self.assertFalse(PROBE.evaluate_gate(rows, dialogs, harness))

    def test_visible_note_with_no_hidden_windows_row_fails_the_gate(self):
        rows = [{"name": "Find in page", "passed": True, "proven": True}]
        dialogs = [{"kind": "visible", "class": "NSWindow"}]
        self.assertFalse(PROBE.visible_notes_fail_their_row(rows, dialogs))
        self.assertFalse(PROBE.evaluate_gate(
            rows, dialogs, {"passed": True, "proven": True}))

    def test_open_panel_does_not_count_as_a_visible_window(self):
        rows = [{"name": "Hidden windows", "passed": True, "proven": True}]
        dialogs = [{"kind": "open-panel", "class": "NSOpenPanel", "title": "Open"}]
        harness = {"passed": True, "proven": True}
        self.assertTrue(PROBE.visible_notes_fail_their_row(rows, dialogs))
        self.assertTrue(PROBE.evaluate_gate(rows, dialogs, harness))

    def test_real_passes_are_accepted(self):
        rows = [
            {"passed": True, "proven": True},
            {"passed": True},
        ]
        self.assertTrue(PROBE.report_passed(rows))
        self.assertEqual(
            PROBE.markdown_table([{"name": "Find in page", "passed": True, "proven": False}]),
            "\n".join([
                "## Part B",
                "",
                "| Check | Result | Detail |",
                "| --- | --- | --- |",
                "| Find in page | FAIL |  |",
            ]),
        )
