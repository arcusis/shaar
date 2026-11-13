# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
import json
import tempfile
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

    def test_unreadable_crash_report_is_owned(self):
        self.assertTrue(PROBE.crash_is_owned({"unreadable": True}, 10, 20))
        self.assertFalse(PROBE.crash_is_owned({}, 10, 20))
        self.assertTrue(PROBE.crash_is_owned({"pid": 10, "parentPid": 1}, 10, 20))
        self.assertFalse(PROBE.crash_is_owned({"pid": 99, "parentPid": 98}, 10, 20))

    def test_unreadable_report_file_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "ShaarVerification-test.ips").write_text("header\nnot-json\n")
            parsed = json.dumps({"pid": 10, "parentPid": 4, "exception": {"signal": "SIGSEGV"}})
            (root / "ShaarVerification-owned.ips").write_text("header\n" + parsed + "\n")
            original = PROBE.CRASHES
            PROBE.CRASHES = root
            try:
                self.assertEqual(
                    PROBE.crash_process("ShaarVerification-test.ips"), {"unreadable": True})
                self.assertTrue(PROBE.owned_crash("ShaarVerification-test.ips", 1, 2))
                self.assertTrue(PROBE.owned_crash("ShaarVerification-owned.ips", 10, 2))
                self.assertFalse(PROBE.owned_crash("ShaarVerification-owned.ips", 99, 98))
                self.assertEqual(PROBE.crash_process("missing.ips"), {})
            finally:
                PROBE.CRASHES = original

    def test_quit_hang_fails_the_harness_row(self):
        self.assertFalse(PROBE.process_stayed_up(True, 0, False, True))
        self.assertTrue(PROBE.process_stayed_up(True, 0, False, False))
        self.assertFalse(PROBE.process_stayed_up(True, 0, True, False))
        self.assertFalse(PROBE.process_stayed_up(False, 0, False, False))

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

    def test_receipt_writer_rejects_symlinked_file_and_parent(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as outside:
            root = Path(directory)
            external = Path(outside)
            sentinel = external / "sentinel.json"
            sentinel.write_text("preserve", encoding="utf-8")

            linked_file = root / "receipt.json"
            linked_file.symlink_to(sentinel)
            with self.assertRaisesRegex(ValueError, "receipt path must not be a symlink"):
                PROBE.write_receipt(linked_file, {"passed": True})
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve")

            linked_parent = root / "linked"
            linked_parent.symlink_to(external, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "receipt directory must not be a symlink"):
                PROBE.write_receipt(linked_parent / "receipt.json", {"passed": True})
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve")
            self.assertFalse((external / "receipt.json").exists())

    def test_receipt_writer_rejects_paths_inside_verification_app(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Verification.app"
            executable = app / "Contents/MacOS/ShaarVerification"
            executable.parent.mkdir(parents=True)
            executable.write_text("executable", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "receipt path must be outside the verification app"):
                PROBE.write_receipt(executable, {"passed": True}, app)

            self.assertEqual(executable.read_text(encoding="utf-8"), "executable")

    def test_note_cap_fails_a_hidden_windows_row_that_claims_a_pass(self):
        rows = [{"name": "Hidden windows", "passed": True, "proven": True}]
        harness = {"passed": True, "proven": True}
        self.assertFalse(PROBE.note_cap_fails_its_row(rows, True))
        self.assertFalse(PROBE.evaluate_gate(rows, [], harness, True))
        self.assertTrue(PROBE.evaluate_gate(rows, [], harness, False))

    def test_note_cap_with_no_hidden_windows_row_fails_the_gate(self):
        rows = [{"name": "Find in page", "passed": True, "proven": True}]
        self.assertFalse(PROBE.note_cap_fails_its_row(rows, True))
        self.assertFalse(PROBE.evaluate_gate(
            rows, [], {"passed": True, "proven": True}, True))

    def test_note_cap_passes_when_the_row_failed(self):
        rows = [{"name": "Hidden windows", "passed": False, "proven": True}]
        self.assertTrue(PROBE.note_cap_fails_its_row(rows, True))

    def test_scroll_fixture_records_page_listener_delivery(self):
        fixture = PROBE.SCROLL.decode()
        self.assertIn('window.__scrollEvents = 0', fixture)
        self.assertIn('window.__scrollEvents += 1', fixture)
        self.assertIn('addEventListener("scroll"', fixture)

    def test_scroll_fixture_requires_scrollend_listener_delivery(self):
        fixture = PROBE.SCROLL.decode()
        self.assertIn('window.__scrollEndEvents = 0', fixture)
        self.assertIn('window.__scrollEndEvents += 1', fixture)
        self.assertIn('addEventListener("scrollend"', fixture)
        source = (ROOT / 'Sources/ShaarVerification/ShaarBrowsingEdgeProbe.swift').read_text()
        self.assertIn('let scrollEndEvents = number(second?["scrollEndEvents"]) ?? 0', source)
        self.assertIn('scrollEvents > 0 && scrollEndEvents > 0', source)
        self.assertIn('window.scrollTo(0, document.documentElement.scrollHeight)', fixture)
        self.assertIn('let pageScrollEvents = number(second?["pageScrollEvents"]) ?? 0', source)
        self.assertIn('scrollEvents > 0 && scrollEndEvents > 0 && pageScrollEvents > 0', source)

    def test_scroll_failure_is_unproven_without_a_page_event(self):
        source = (ROOT / 'Sources/ShaarVerification/ShaarBrowsingEdgeProbe.swift').read_text()
        self.assertIn(
            'proven: scrollFailureIsAttributable(scrollEvents: scrollEvents)', source)

    def test_media_fixture_rejects_a_paused_video_with_dimensions(self):
        fixture = PROBE.MEDIA.decode()
        self.assertIn('!video.paused && video.videoWidth > 0', fixture)
