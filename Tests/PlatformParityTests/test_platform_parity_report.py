# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
import signal
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "platform_parity", ROOT / "scripts/test-platform-parity.py")
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class PlatformParityReportTests(unittest.TestCase):
    def test_setup_rows_do_not_count_as_checks(self):
        rows = [
            {"item": "Setup", "result": "fail"},
            {"item": "Safe Browsing state", "result": "fail"},
            {"item": "Web Serial chooser", "result": "in progress"},
        ]
        self.assertFalse(PROBE.checks_ran(rows))
        report = {"completed": True, "allWindowsHidden": True, "rows": rows}
        self.assertFalse(PROBE.run_completed(report, []))

    def test_a_finished_checklist_row_counts(self):
        rows = [{"item": "Camera permission", "result": "pass"}]
        report = {"completed": True, "allWindowsHidden": True, "rows": rows}
        self.assertTrue(PROBE.run_completed(report, []))
        self.assertFalse(PROBE.run_completed(report, ["helper.ips"]))
        hidden = {"completed": True, "allWindowsHidden": False, "rows": rows}
        self.assertFalse(PROBE.run_completed(hidden, []))
        unfinished = {"completed": False, "allWindowsHidden": True, "rows": rows}
        self.assertFalse(PROBE.run_completed(unfinished, []))

    def test_group_parser_keeps_exact_pids(self):
        text = "  10 10\n  11 10\n  12 55\n  1 10\n  bad line\n"
        self.assertEqual(PROBE.parse_group_pids(text, 10), [10, 11])

    def test_recycled_pid_is_not_signaled(self):
        alive = PROBE.pid_alive
        group = PROBE.process_group
        try:
            PROBE.pid_alive = lambda pid: True
            groups = {10: 10, 11: 10, 12: 55}
            PROBE.process_group = lambda pid: groups.get(pid)
            self.assertEqual(PROBE.pids_to_signal([10, 11, 12, 1], 10), [10, 11])
        finally:
            PROBE.pid_alive = alive
            PROBE.process_group = group

    def test_stop_signals_exact_pids(self):
        killed = []
        alive = PROBE.pid_alive
        kill = PROBE.os.kill
        killpg = PROBE.os.killpg
        state = {10: True, 11: True}
        try:
            PROBE.pid_alive = lambda pid: state.get(pid, False)

            def record(pid, sig):
                killed.append((pid, sig))
                if sig == signal.SIGKILL:
                    state[pid] = False

            def reject_group(*_args):
                raise AssertionError("killpg")

            PROBE.os.kill = record
            PROBE.os.killpg = reject_group
            PROBE.signal_exact_pids([10, 11])
        finally:
            PROBE.pid_alive = alive
            PROBE.os.kill = kill
            PROBE.os.killpg = killpg
        self.assertEqual(killed, [
            (10, signal.SIGTERM), (11, signal.SIGTERM),
            (10, signal.SIGKILL), (11, signal.SIGKILL),
        ])

    def test_helper_crash_pid_matches(self):
        text = 'Process: Chromium Helper\n"pid" : 4242\n'
        self.assertTrue(PROBE.crash_matches_pids(text, [90066, 4242]))
        self.assertFalse(PROBE.crash_matches_pids(text, [90066]))
