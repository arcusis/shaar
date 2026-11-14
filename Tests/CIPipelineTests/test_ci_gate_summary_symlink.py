# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location("ci_gate", ROOT / "scripts/ci-gate.py")
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


class CIGateSummarySymlinkTests(unittest.TestCase):
    def test_gate_rejects_symlinked_step_summary_without_appending(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            summary = root / "step-summary.md"
            external = root / "external.txt"
            external.write_text("preserve this summary")
            summary.symlink_to(external)
            needs = {name: {"result": "success"}
                     for name in ("plan", "fast", "dependency-review", "codeql")}
            environment = {
                "CI_NEEDS": json.dumps(needs),
                "CI_FULL": "false",
                "CI_NIGHTLY": "false",
                "GITHUB_STEP_SUMMARY": str(summary),
            }

            with patch.dict(os.environ, environment, clear=True), patch("sys.stdout", io.StringIO()):
                with self.assertRaisesRegex(ValueError, "CI evidence output must not be a symlink"):
                    GATE.main()

            self.assertEqual(external.read_text(), "preserve this summary")


if __name__ == "__main__":
    unittest.main()
