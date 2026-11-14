# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location(
    "sync_code_scanning_issues", ROOT / "scripts/sync-code-scanning-issues.py"
)
SCANNING_ISSUES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCANNING_ISSUES)


class CodeScanningPageTests(unittest.TestCase):
    def test_non_list_page_responses_are_rejected(self):
        path = "repos/arcusis/shaar/code-scanning/alerts?state=open"
        with patch.object(SCANNING_ISSUES, "gh", return_value={"message": "temporary response"}):
            with self.assertRaisesRegex(ValueError, "non-list response for .*code-scanning/alerts"):
                SCANNING_ISSUES.paged(path)

    def test_non_object_page_rows_are_rejected(self):
        path = "repos/arcusis/shaar/code-scanning/alerts?state=open"
        with patch.object(SCANNING_ISSUES, "gh", return_value=[None]):
            with self.assertRaisesRegex(ValueError, "non-object entry 0 for .*code-scanning/alerts"):
                SCANNING_ISSUES.paged(path)
