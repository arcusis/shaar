# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location("ci_plan", ROOT / "scripts/ci-plan.py")
PLAN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PLAN)


class CIPlanControlFileSymlinkTests(unittest.TestCase):
    def test_plan_rejects_symlinked_github_files_before_writing_either(self):
        for linked_name in ("GITHUB_OUTPUT", "GITHUB_STEP_SUMMARY"):
            with self.subTest(linked_name=linked_name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                event = root / "event.json"
                event.write_text(json.dumps({
                    "pull_request": {"base": {"sha": "a" * 40}, "draft": False}
                }))
                output = root / "output"
                summary = root / "summary.md"
                external = root / "external.txt"
                external.write_text("preserve this control file")
                linked = output if linked_name == "GITHUB_OUTPUT" else summary
                linked.symlink_to(external)
                environment = {
                    "GITHUB_EVENT_PATH": str(event),
                    "GITHUB_EVENT_NAME": "pull_request",
                    "GITHUB_SHA": "b" * 40,
                    "GITHUB_OUTPUT": str(output),
                    "GITHUB_STEP_SUMMARY": str(summary),
                }
                result = type("Diff", (), {"returncode": 0, "stdout": b""})()

                with patch.dict(os.environ, environment, clear=True), \
                        patch.object(PLAN.subprocess, "run", return_value=result):
                    with self.assertRaisesRegex(ValueError, "CI evidence output must not be a symlink"):
                        PLAN.main()

                self.assertEqual(external.read_text(), "preserve this control file")
                if linked_name == "GITHUB_STEP_SUMMARY":
                    self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
