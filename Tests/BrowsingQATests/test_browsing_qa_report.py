# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "browsing_qa", ROOT / "scripts/test-browsing-qa.py")
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)

GIBIBYTE = 1024 ** 3


class BrowsingQAReportTests(unittest.TestCase):
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

    def test_deliberate_renderer_sigkill_is_not_a_second_defect(self):
        report = {"rows": [{"name": "renderer-recover", "status": "pass"}]}
        self.assertFalse(PROBE.crash_counts_against_suite("renderer", report, "EXC_CRASH SIGKILL"))
        self.assertTrue(PROBE.crash_counts_against_suite("renderer", report, "EXC_BAD_ACCESS"))
        self.assertTrue(PROBE.crash_counts_against_suite("windows", report, "SIGKILL"))

    def test_suite_passes_when_every_scenario_is_pass_or_blocked(self):
        self.assertTrue(PROBE.suite_passed([{"result": "pass"}, {"result": "blocked"}]))
        self.assertFalse(PROBE.suite_passed([{"result": "pass"}, {"result": "hang"}]))

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


if __name__ == "__main__":
    unittest.main()
