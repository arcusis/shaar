# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location("ci_stage", ROOT / "scripts/ci-stage.py")
STAGES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STAGES)


class CIStageErrorOutputSymlinkTests(unittest.TestCase):
    def test_stage_error_outputs_reject_symlinks_before_writing_either_file(self):
        for linked_name in ("error.txt", "stage-error.log"):
            with self.subTest(linked_name=linked_name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                stage = root / "build/ci/unit"
                stage.mkdir(parents=True)
                outside = root / "external.log"
                outside.write_text("preserve this evidence")
                (stage / linked_name).symlink_to(outside)

                with patch("ci_support.ROOT", root):
                    checks = STAGES.Commands("unit")
                    with self.assertRaisesRegex(ValueError, "CI evidence output must not be a symlink"):
                        STAGES.record_stage_error(checks, RuntimeError("stage failed"))

                self.assertEqual(outside.read_text(), "preserve this evidence")
                self.assertFalse((stage / "error.txt").exists() and not (stage / "error.txt").is_symlink())
                self.assertFalse((stage / "stage-error.log").exists()
                                 and not (stage / "stage-error.log").is_symlink())
                self.assertEqual(checks.results, [])


if __name__ == "__main__":
    unittest.main()
