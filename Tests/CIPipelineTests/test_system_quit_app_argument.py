# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from contextlib import redirect_stderr
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "test_shaar_system_quit", ROOT / "scripts/test-shaar-system-quit.py")
SYSTEM_QUIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SYSTEM_QUIT)


class SystemQuitAppArgumentTests(unittest.TestCase):
    def test_missing_verification_executable_is_rejected_before_fixture_setup(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "Shaar Verification.app"
            app.mkdir()
            stderr = io.StringIO()
            with (
                patch.object(sys, "argv", [
                    "test-shaar-system-quit.py", "--app", str(app),
                    "--fixture-url", "http://127.0.0.1:1234/",
                ]),
                patch.object(SYSTEM_QUIT.tempfile, "TemporaryDirectory") as temporary_directory,
                redirect_stderr(stderr),
                self.assertRaises(SystemExit) as raised,
            ):
                SYSTEM_QUIT.main()
            self.assertEqual(raised.exception.code, 2)
            self.assertIn("not a Shaar verification app", stderr.getvalue())
            temporary_directory.assert_not_called()
