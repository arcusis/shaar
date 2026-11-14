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
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location(
    "test_shaar_devtools_route", ROOT / "scripts/test-shaar-devtools-route.py")
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class ShaarDevToolsRouteReceiptPathTests(unittest.TestCase):
    def test_cli_rejects_symlinked_receipts_before_probe_setup(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "Shaar Verification.app"
            executable = app / "Contents/MacOS/ShaarVerification"
            executable.parent.mkdir(parents=True)
            executable.write_text("fixture")
            outside = root / "outside"
            outside.mkdir()
            external = outside / "external.json"
            external.write_text("preserve this receipt")
            receipt = root / "receipt.json"
            receipt.symlink_to(external)
            parent_receipt = outside / "parent-receipt.json"
            parent_receipt.write_text("preserve this parent receipt")
            linked_parent = root / "linked-parent"
            linked_parent.symlink_to(outside, target_is_directory=True)

            cases = ((receipt, "receipt output must not be a symlink"),
                     (linked_parent / "parent-receipt.json",
                      "receipt output parent must not be a symlink"))
            for path, message in cases:
                with self.subTest(path=path):
                    stderr = io.StringIO()
                    with patch.object(sys, "argv", ["test-shaar-devtools-route.py",
                                                     "--app", str(app),
                                                     "--receipt", str(path)]), \
                            patch.object(PROBE, "ThreadingHTTPServer") as server, \
                            patch.object(PROBE.threading, "Thread") as thread, \
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

            self.assertEqual(external.read_text(), "preserve this receipt")
            self.assertEqual(parent_receipt.read_text(), "preserve this parent receipt")


if __name__ == "__main__":
    unittest.main()
