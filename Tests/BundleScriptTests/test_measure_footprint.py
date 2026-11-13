# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "measure_footprint", REPO / "scripts" / "measure-footprint.py")
measure_footprint = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(measure_footprint)


def thread(total, frames, trailer=""):
    lines = [
        f"    {total} Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)",
        *frames,
    ]
    if trailer:
        lines.append(trailer)
    lines.append(f"    {total} Thread_2")
    lines.append("    + 4000 __workq_kernreturn  (in libsystem_kernel.dylib) + 8")
    return "\n".join(lines)


class MeasureFootprintSampleTests(unittest.TestCase):
    def test_report_writer_rejects_symlink_without_overwriting_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "outside.json"
            target.write_text("preserve this", encoding="utf-8")
            output = root / "report.json"
            output.symlink_to(target)

            with self.assertRaisesRegex(ValueError, "performance report path must not be a symlink"):
                measure_footprint.write_report(output, {"schema": 3})

            self.assertEqual(target.read_text(encoding="utf-8"), "preserve this")

    def test_sleeping_comparison_reports_rss_saved_per_tab_count(self):
        comparisons = measure_footprint.compare_sleeping_rss([
            {"tabs": 50, "mode": "eager", "processTreeRSSMiBMean": 900.0},
            {"tabs": 50, "mode": "sleeping", "processTreeRSSMiBMean": 540.0},
            {"tabs": 100, "mode": "eager", "processTreeRSSMiBMean": 1600.0},
            {"tabs": 100, "mode": "sleeping", "processTreeRSSMiBMean": 800.0},
        ])
        self.assertEqual(comparisons, [
            {
                "tabs": 50,
                "awakeProcessTreeRSSMiBMean": 900.0,
                "sleepingProcessTreeRSSMiBMean": 540.0,
                "processTreeRSSMiBSaved": 360.0,
                "processTreeRSSReductionPercent": 40.0,
            },
            {
                "tabs": 100,
                "awakeProcessTreeRSSMiBMean": 1600.0,
                "sleepingProcessTreeRSSMiBMean": 800.0,
                "processTreeRSSMiBSaved": 800.0,
                "processTreeRSSReductionPercent": 50.0,
            },
        ])

    def test_sleeping_comparison_omits_counts_without_both_modes(self):
        comparisons = measure_footprint.compare_sleeping_rss([
            {"tabs": 50, "mode": "eager", "processTreeRSSMiBMean": 900.0},
            {"tabs": 100, "mode": "sleeping", "processTreeRSSMiBMean": 800.0},
        ])
        self.assertEqual(comparisons, [])

    def test_sample_duration_must_be_positive_integer(self):
        self.assertEqual(measure_footprint.positive_seconds("15"), 15)
        for value in ("0", "-1", "1.5", "invalid"):
            with self.subTest(value=value), self.assertRaises(
                measure_footprint.argparse.ArgumentTypeError
            ):
                measure_footprint.positive_seconds(value)

    def test_busy_parent_outranks_a_smaller_child(self):
        parsed = measure_footprint.parse_main_thread_sample(thread(100, [
            "    + 100 doWork  (in Shaar)",
            "    +   60 mach_msg2_trap  (in libsystem_kernel.dylib)",
            "    +   25 realWork  (in Shaar)",
            "    +   15 otherWork  (in Shaar)",
        ]))
        self.assertEqual(parsed["mainThreadWaitSamples"], 60)
        self.assertEqual(parsed["mainThreadBusyPercent"], 40.0)
        self.assertFalse(parsed["mainThreadHang"])
        self.assertTrue(parsed["mainThreadTopFrame"].startswith("doWork"))

    def test_equal_busy_counts_prefer_the_deeper_frame(self):
        parsed = measure_footprint.parse_main_thread_sample(thread(100, [
            "    + 100 -[NSRunLoop run]  (in Foundation)",
            "    +   70 mach_msg2_trap  (in libsystem_kernel.dylib)",
            "    +   30 realWork  (in Shaar)",
        ]))
        self.assertEqual(parsed["mainThreadWaitSamples"], 70)
        self.assertTrue(parsed["mainThreadTopFrame"].startswith("realWork"))

    def test_start_symbol_match_keeps_startup_frames(self):
        parsed = measure_footprint.parse_main_thread_sample(thread(10, [
            "    + 10 start  (in dyld) + 6992",
            "    +   10 startupTask  (in Shaar)",
            "    +     6 mach_msg2_trap  (in libsystem_kernel.dylib)",
            "    +     4 startupTaskWork  (in Shaar)",
        ]))
        self.assertEqual(parsed["mainThreadWaitSamples"], 6)
        self.assertTrue(parsed["mainThreadTopFrame"].startswith("startupTaskWork"))
        self.assertNotIn("dyld", parsed["mainThreadTopFrame"])

    def test_newer_kernel_waits_count_and_a_busy_leaf_remains(self):
        traps = [
            "mach_msg_overwrite_trap",
            "semaphore_wait_signal_trap",
            "semaphore_timedwait_signal_trap",
            "__semwait_signal",
            "__semwait_signal_nocancel",
            "__psynch_rw_wrlock",
            "__psynch_rw_rdlock",
        ]
        frames = ["    + 8 doWork  (in Shaar)"]
        for trap in traps:
            frames.append(f"    +   1 {trap}  (in libsystem_kernel.dylib)")
        frames.append("    +   1 realWork  (in Shaar)")
        parsed = measure_footprint.parse_main_thread_sample(thread(8, frames))
        self.assertEqual(parsed["mainThreadSamples"], 8)
        self.assertEqual(parsed["mainThreadWaitSamples"], 7)
        self.assertEqual(parsed["mainThreadBusyPercent"], 12.5)
        self.assertFalse(parsed["mainThreadHang"])
        self.assertTrue(parsed["mainThreadTopFrame"].startswith("realWork"))

    def test_process_wide_sort_section_stays_out_of_the_main_thread(self):
        parsed = measure_footprint.parse_main_thread_sample(thread(
            10,
            ["    + 10 realWork  (in Shaar)"],
            trailer="\n".join([
                "Sort by top of stack",
                "    6548 kevent64  (in libsystem_kernel.dylib)",
                "    52371 mach_msg2_trap  (in libsystem_kernel.dylib)",
            ]),
        ))
        self.assertEqual(parsed["mainThreadSamples"], 10)
        self.assertEqual(parsed["mainThreadWaitSamples"], 0)
        self.assertTrue(parsed["mainThreadHang"])
        self.assertTrue(parsed["mainThreadTopFrame"].startswith("realWork"))

    def test_fully_idle_main_thread_has_no_top_frame(self):
        parsed = measure_footprint.parse_main_thread_sample(thread(4, [
            "    + 4 start  (in dyld)",
            "    +   4 mach_msg2_trap  (in libsystem_kernel.dylib)",
        ]))
        self.assertEqual(parsed["mainThreadWaitSamples"], 4)
        self.assertEqual(parsed["mainThreadBusyPercent"], 0.0)
        self.assertEqual(parsed["mainThreadTopFrame"], "")
        self.assertFalse(parsed["mainThreadHang"])


if __name__ == "__main__":
    unittest.main()
