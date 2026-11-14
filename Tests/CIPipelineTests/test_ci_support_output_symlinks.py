# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

class CIOutputSymlinkTests(unittest.TestCase):
    def test_command_metadata_rejects_symlink_without_overwriting_target(self):
        from ci_support import Commands
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage = root / "build/ci/fast"
            stage.mkdir(parents=True)
            external = root / "external.json"
            external.write_text("preserve this report")
            (stage / "metadata.json").symlink_to(external)

            with patch("ci_support.ROOT", root), self.assertRaisesRegex(
                ValueError, "CI evidence output must not be a symlink"
            ):
                Commands("fast")

            self.assertEqual(external.read_text(), "preserve this report")


if __name__ == "__main__":
    unittest.main()
