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
    "shaar_quit_probe", ROOT / "scripts/probe-shaar-quit.py")
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class OutputDirectorySymlinkTests(unittest.TestCase):
    def test_cli_rejects_symlinked_output_directories_before_app_check(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            outside = root / "outside"
            outside.mkdir()
            linked_output = root / "linked-output"
            linked_output.symlink_to(outside, target_is_directory=True)
            linked_parent = root / "linked-parent"
            linked_parent.symlink_to(outside, target_is_directory=True)

            cases = ((linked_output, "output directory must not be a symlink"),
                     (linked_parent / "nested", "output directory parent must not be a symlink"))
            for path, message in cases:
                with self.subTest(path=path):
                    stderr = io.StringIO()
                    with patch.object(sys, "argv", ["probe-shaar-quit.py",
                                                     "--app", str(root / "missing.app"),
                                                     "--output-dir", str(path)]), \
                            redirect_stderr(stderr), self.assertRaises(SystemExit) as raised:
                        PROBE.main()

                    self.assertEqual(raised.exception.code, 2)
                    self.assertIn(message, stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
