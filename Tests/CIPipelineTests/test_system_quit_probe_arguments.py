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
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class SystemQuitProbeArgumentTests(unittest.TestCase):
    def test_app_and_fixture_arguments_fail_clearly_before_probe(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "verification.app"
            app.mkdir()
            cases = (
                (root / "missing.app", "http://127.0.0.1:12345/fixture",
                 "verification app directory does not exist"),
                (app, "http://127.0.0.1:not-a-port/fixture",
                 "fixture URL must use http://127.0.0.1:<port>"),
            )
            for app_path, fixture_url, message in cases:
                with self.subTest(app=app_path, fixture_url=fixture_url):
                    stderr = io.StringIO()
                    with patch.object(sys, "argv", ["test-shaar-system-quit.py",
                                                     "--app", str(app_path),
                                                     "--fixture-url", fixture_url]), \
                            patch.object(PROBE, "run_case") as run_case, \
                            redirect_stderr(stderr), self.assertRaises(SystemExit) as raised:
                        PROBE.main()

                    self.assertEqual(raised.exception.code, 2)
                    self.assertIn(message, stderr.getvalue())
                    run_case.assert_not_called()


if __name__ == "__main__":
    unittest.main()
