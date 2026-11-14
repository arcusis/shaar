# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from contextlib import redirect_stderr
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "inspector_idle_shipping", ROOT / "scripts/test-inspector-idle-shipping.py")
INSPECTOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSPECTOR)


class InspectorReceiptSymlinkTests(unittest.TestCase):
    def test_cli_rejects_symlinked_receipt_paths_before_starting_probe(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "Shaar Verification.app"
            executable = app / "Contents/MacOS/ShaarVerification"
            executable.parent.mkdir(parents=True)
            executable.write_text("fixture")

            external = root / "external.json"
            external.write_text("preserve this receipt")
            receipt = root / "receipt.json"
            receipt.symlink_to(external)
            outside = root / "outside"
            outside.mkdir()
            parent_receipt = outside / "receipt.json"
            parent_receipt.write_text("preserve this parent receipt")
            linked_parent = root / "linked-parent"
            linked_parent.symlink_to(outside, target_is_directory=True)

            def run_probe(arguments, **_kwargs):
                report = Path(arguments[arguments.index("--inspector-idle-smoke") + 1])
                report.write_text(json.dumps({"passed": True}))
                return subprocess.CompletedProcess(arguments, 0, stdout="", stderr="")

            cases = ((receipt, "receipt output must not be a symlink"),
                     (linked_parent / "receipt.json", "receipt output parent must not be a symlink"))
            for path, message in cases:
                with self.subTest(path=path):
                    stderr = io.StringIO()
                    with patch.object(sys, "argv", ["test-inspector-idle-shipping.py", "--app", str(app),
                                                     "--receipt", str(path)]), \
                            patch.object(INSPECTOR, "ThreadingHTTPServer") as server, \
                            patch.object(INSPECTOR.threading, "Thread") as thread, \
                            patch.object(INSPECTOR, "crash_names", return_value=set()) as crashes, \
                            patch.object(INSPECTOR.subprocess, "run", side_effect=run_probe) as run, \
                            redirect_stderr(stderr), self.assertRaises(SystemExit) as raised:
                        INSPECTOR.main()

                    self.assertEqual(raised.exception.code, 2)
                    self.assertIn(message, stderr.getvalue())
                    server.assert_not_called()
                    thread.assert_not_called()
                    crashes.assert_not_called()
                    run.assert_not_called()

            self.assertEqual(external.read_text(), "preserve this receipt")
            self.assertEqual(parent_receipt.read_text(), "preserve this parent receipt")


if __name__ == "__main__":
    unittest.main()
