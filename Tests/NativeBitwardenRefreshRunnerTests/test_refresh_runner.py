import importlib.util
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("refresh_runner", ROOT / "scripts/test-native-bitwarden-refresh.py")
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class RefreshRunnerTests(unittest.TestCase):
    def test_build_rejects_each_changed_input_and_removes_old_stamp(self):
        before = {"manifest": "a", "sources": {"source": "a"}, "runner": "a"}
        for key in before:
            with self.subTest(key=key), tempfile.TemporaryDirectory() as directory:
                stamp = Path(directory) / "stamp.json"
                stamp.write_text("old")
                after = dict(before)
                after[key] = {"source": "b"} if key == "sources" else "b"
                with patch.object(runner, "STAMP", stamp), \
                     patch.object(runner, "input_fingerprints", side_effect=[before, after]), \
                     patch.object(runner, "run_owned_build"):
                    with self.assertRaisesRegex(RuntimeError, "changed during build"):
                        runner.build("a")
                self.assertFalse(stamp.exists())

    def test_prebuilt_rechecks_package_and_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "binary"
            binary.write_bytes(b"owned")
            stamp = root / "stamp.json"
            inputs = {"manifest": "a", "sources": {"source": "a"}, "runner": "a"}
            stamp.write_text(json.dumps(inputs | {"test_binary": runner.digest(binary)}))
            with patch.object(runner, "STAMP", stamp), patch.object(runner, "BINARY", binary), \
                 patch.object(runner, "XCTEST", binary), \
                 patch.object(runner, "input_fingerprints", return_value=inputs):
                runner.validate_prebuilt("a")
                inputs["sources"] = {"source": "changed"}
                with self.assertRaisesRegex(RuntimeError, "inputs changed"):
                    runner.validate_prebuilt("a")
            with patch.object(runner, "STAMP", stamp), patch.object(runner, "BINARY", binary), \
                 patch.object(runner, "input_fingerprints", side_effect=RuntimeError("package drift")):
                with self.assertRaisesRegex(RuntimeError, "package drift"):
                    runner.validate_prebuilt("a")

    def test_interrupted_build_terminates_owned_process_group(self):
        with tempfile.TemporaryDirectory() as directory:
            pidfile = Path(directory) / "pids"
            code = (
                "import os, subprocess, sys, time; "
                "p=subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)']); "
                "open(sys.argv[1], 'w').write(str(os.getpid())+' '+str(p.pid)); "
                "time.sleep(60)"
            )
            popen = runner.subprocess.Popen
            owned = []
            def spawn(*args, **kwargs):
                process = popen(*args, **kwargs)
                owned.append(process)
                deadline = time.monotonic() + 5
                while not pidfile.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                if not pidfile.exists():
                    runner.terminate_owned_group(process)
                    raise RuntimeError("synthetic child did not start")
                process.communicate = Mock(side_effect=KeyboardInterrupt())
                return process
            try:
                with patch.object(runner.subprocess, "Popen", side_effect=spawn):
                    with self.assertRaises(KeyboardInterrupt):
                        runner.run_owned_build([sys.executable, "-c", code, str(pidfile)],
                                               runner.clean_environment(), timeout=5)
                leader, child = map(int, pidfile.read_text().split())
                self.assertFalse(runner.process_group_exists(leader))
                for pid in (leader, child):
                    with self.assertRaises(ProcessLookupError):
                        os.kill(pid, 0)
            finally:
                if owned and runner.process_group_exists(owned[0].pid):
                    runner.terminate_owned_group(owned[0])

    def test_timeout_terminates_owned_process_group(self):
        with tempfile.TemporaryDirectory() as directory:
            pidfile = Path(directory) / "pids"
            code = (
                "import os, subprocess, sys, time; "
                "p=subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)']); "
                "open(sys.argv[1], 'w').write(str(os.getpid())+' '+str(p.pid)); "
                "time.sleep(60)"
            )
            with self.assertRaisesRegex(RuntimeError, "timed out; owned group exited"):
                runner.run_owned_build([sys.executable, "-c", code, str(pidfile)],
                                       runner.clean_environment(), timeout=1)
            leader, child = map(int, pidfile.read_text().split())
            self.assertFalse(runner.process_group_exists(leader))
            for pid in (leader, child):
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)


if __name__ == "__main__":
    unittest.main()
