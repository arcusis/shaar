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
SPEC = importlib.util.spec_from_file_location(
    "check_codeql_extraction", ROOT / "scripts/check-codeql-extraction.py")
EXTRACTION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EXTRACTION)


class CodeQLReportOutputSymlinkTests(unittest.TestCase):
    def test_extraction_check_rejects_symlinked_outputs_before_writing(self):
        for linked_name in ("coverage.json", "summary.md"):
            with self.subTest(linked_name=linked_name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                source = root / "Sources/Test.swift"
                source.parent.mkdir(parents=True)
                source.write_text("struct Test {}\n")
                report = root / "extraction.json"
                report.write_text(json.dumps({
                    "#select": {"tuples": [[{"label": "Sources/Test.swift"}, "extracted"]]}
                }))
                coverage = root / "coverage.json"
                summary = root / "summary.md"
                external = root / "external.txt"
                external.write_text("preserve this output")
                (coverage if linked_name == "coverage.json" else summary).symlink_to(external)

                with patch.object(EXTRACTION, "ROOT", root), \
                        patch.object(sys, "argv", ["check-codeql-extraction.py", str(report)]), \
                        patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(summary)}, clear=True):
                    self.assertEqual(EXTRACTION.main(), 2)

                self.assertEqual(external.read_text(), "preserve this output")
                if linked_name == "summary.md":
                    self.assertFalse(coverage.exists())


if __name__ == "__main__":
    unittest.main()
