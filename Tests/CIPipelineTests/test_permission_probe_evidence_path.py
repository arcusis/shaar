# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from contextlib import redirect_stderr
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "test_shaar_permission_prompt", ROOT / "scripts/test-shaar-permission-prompt.py")
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class PermissionProbeEvidencePathTests(unittest.TestCase):
    def test_cli_rejects_symlinked_evidence_directories_before_probe_setup(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            outside = root / "outside"
            outside.mkdir()
            (outside / "preserve.txt").write_text("preserve this")
            linked_directory = root / "linked-evidence"
            linked_directory.symlink_to(outside, target_is_directory=True)
            linked_parent = root / "linked-parent"
            linked_parent.symlink_to(outside, target_is_directory=True)

            cases = ((linked_directory, "evidence directory must not be a symlink"),
                     (linked_parent / "evidence",
                      "evidence directory parent must not be a symlink"))
            for path, message in cases:
                with self.subTest(path=path):
                    stderr = io.StringIO()
                    with patch.object(sys, "argv", ["test-shaar-permission-prompt.py",
                                                     "--app", str(root / "missing.app"),
                                                     "--evidence", str(path)]), \
                            patch.object(PROBE, "ThreadingHTTPServer") as server, \
                            patch.object(PROBE.threading, "Thread") as thread, \
                            patch.object(PROBE, "crash_names", return_value=set()), \
                            patch.object(PROBE.subprocess, "run",
                                         return_value=subprocess.CompletedProcess([], 0,
                                                                                 stdout="",
                                                                                 stderr="")) as run, \
                            redirect_stderr(stderr), self.assertRaises(SystemExit) as raised:
                        PROBE.main()

                    self.assertEqual(raised.exception.code, 2)
                    self.assertIn(message, stderr.getvalue())
                    server.assert_not_called()
                    thread.assert_not_called()
                    run.assert_not_called()

            self.assertFalse((outside / "stderr.txt").exists())
            self.assertEqual((outside / "preserve.txt").read_text(), "preserve this")


if __name__ == "__main__":
    unittest.main()
