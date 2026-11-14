# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from contextlib import redirect_stderr
import importlib.util
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "test_shaar_favicon", ROOT / "scripts/test-shaar-favicon.py")
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class FaviconEvidenceSymlinkTests(unittest.TestCase):
    def test_main_rejects_symlinked_evidence_output_before_capture(self):
        passed = {"passed": True, "allWindowsHidden": True, "faviconObserved": True,
                  "faviconCacheRestored": True, "inactiveFaviconObserved": True,
                  "favoriteFaviconCached": True, "restoredPinIcon": True,
                  "restoredFavoriteIcon": True, "restoredPinFromCache": True,
                  "restoredFavoriteDormant": True, "sidebarIconPixels": 800}
        original_cwd = Path.cwd()
        try:
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                app = root / "Shaar Verification.app"
                executable = app / "Contents/MacOS/ShaarVerification"
                executable.parent.mkdir(parents=True)
                executable.write_text("fixture")

                for kind in ("directory", "parent"):
                    with self.subTest(kind=kind):
                        case = root / kind
                        case.mkdir()
                        outside = case / "outside"
                        outside.mkdir()
                        (outside / "preserve.txt").write_text("preserve this")
                        build = case / "build"
                        if kind == "directory":
                            build.mkdir()
                            (build / "favicon-1045-evidence").symlink_to(
                                outside, target_is_directory=True)
                            message = "favicon evidence output must not be a symlink"
                        else:
                            build.symlink_to(outside, target_is_directory=True)
                            message = "favicon evidence output parent must not be a symlink"

                        def run_probe(_app, probe_root, _data, _report, _page, extra):
                            (probe_root / "favicon-sidebar.png").write_bytes(b"fixture image")
                            return None, passed

                        os.chdir(case)
                        try:
                            stderr = io.StringIO()
                            with patch.object(sys, "argv", ["test-shaar-favicon.py",
                                                             "--app", str(app)]), \
                                    patch.object(PROBE, "ThreadingHTTPServer") as server, \
                                    patch.object(PROBE.threading, "Thread") as thread, \
                                    patch.object(PROBE, "run_probe", side_effect=run_probe) as run, \
                                    redirect_stderr(stderr), self.assertRaises(SystemExit) as raised:
                                PROBE.main()

                            self.assertEqual(raised.exception.code, 2)
                            self.assertIn(message, stderr.getvalue())
                            server.assert_not_called()
                            thread.assert_not_called()
                            run.assert_not_called()
                            self.assertFalse((outside / "favicon-sidebar-after-relaunch.png").exists())
                            self.assertEqual((outside / "preserve.txt").read_text(), "preserve this")
                        finally:
                            os.chdir(root)
        finally:
            os.chdir(original_cwd)


if __name__ == "__main__":
    unittest.main()
