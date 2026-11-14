# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))


class CISummarySymlinkTests(unittest.TestCase):
    def test_finish_rejects_symlinked_step_summary_without_appending(self):
        from ci_support import Commands

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            summary = root / "step-summary.md"
            external = root / "external.txt"
            external.write_text("preserve this report")
            summary.symlink_to(external)

            with patch("ci_support.ROOT", root), \
                    patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(summary)}):
                checks = Commands("unit")
                with self.assertRaisesRegex(ValueError, "CI evidence output must not be a symlink"):
                    checks.finish()

            self.assertEqual(external.read_text(), "preserve this report")


if __name__ == "__main__":
    unittest.main()
