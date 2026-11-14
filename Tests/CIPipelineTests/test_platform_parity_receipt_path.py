# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from contextlib import redirect_stderr
import importlib.util
import io
import sys
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "test_platform_parity", ROOT / "scripts/test-platform-parity.py")
PARITY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PARITY)


class PlatformParityReceiptPathTests(unittest.TestCase):
    def test_cli_rejects_symlinked_receipt_paths_before_starting_probe(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            external = root / "external.json"
            external.write_text("preserve this receipt")
            receipt = root / "receipt.json"
            receipt.symlink_to(external)
            outside = root / "outside"
            outside.mkdir()
            parent_sentinel = outside / "keep.txt"
            parent_sentinel.write_text("preserve this directory")
            linked_parent = root / "linked-parent"
            linked_parent.symlink_to(outside, target_is_directory=True)

            cases = ((receipt, "receipt output must not be a symlink"),
                     (linked_parent / "receipt.json", "receipt output parent must not be a symlink"))
            for path, message in cases:
                with self.subTest(path=path):
                    error = io.StringIO()
                    with patch.object(sys, "argv", ["test-platform-parity.py", "--receipt", str(path)]), \
                            redirect_stderr(error), self.assertRaises(SystemExit) as raised:
                        PARITY.main()
                    self.assertEqual(raised.exception.code, 2)
                    self.assertIn(message, error.getvalue())

            self.assertEqual(external.read_text(), "preserve this receipt")
            self.assertEqual(parent_sentinel.read_text(), "preserve this directory")


if __name__ == "__main__":
    unittest.main()
