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
    "test_shaar_https_only", ROOT / "scripts/test-shaar-https-only.py")
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class HttpsOnlyProbeArgumentTests(unittest.TestCase):
    def test_missing_app_is_rejected_before_probe_setup(self):
        with tempfile.TemporaryDirectory() as temporary:
            missing_app = Path(temporary) / "Missing.app"
            stderr = io.StringIO()
            with patch.object(sys, "argv", ["test-shaar-https-only.py",
                                             "--app", str(missing_app)]), \
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
            self.assertIn("verification app is missing", stderr.getvalue())
            server.assert_not_called()
            thread.assert_not_called()
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
