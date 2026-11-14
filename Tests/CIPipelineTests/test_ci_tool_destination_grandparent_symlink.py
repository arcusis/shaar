# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("install_ci_tools", ROOT / "scripts/install-ci-tools.py")
INSTALL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSTALL)


class CIToolDestinationAncestorSymlinkTests(unittest.TestCase):
    def test_installer_rejects_symlinked_ancestor_before_creating_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            outside = root / "outside"
            nested_parent = outside / "nested"
            nested_parent.mkdir(parents=True)
            sentinel = nested_parent / "keep.txt"
            sentinel.write_text("preserve this file")
            linked_parent = root / "linked-parent"
            linked_parent.symlink_to(outside, target_is_directory=True)
            destination = linked_parent / "nested/ci-tools"

            with self.assertRaisesRegex(ValueError, "symlinked ancestor"):
                INSTALL.validate_install_destinations(destination, ["tool"])

            self.assertEqual(sentinel.read_text(), "preserve this file")
            self.assertFalse((nested_parent / "ci-tools").exists())


if __name__ == "__main__":
    unittest.main()
