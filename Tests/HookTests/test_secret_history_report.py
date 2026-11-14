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
SPEC = importlib.util.spec_from_file_location(
    "check_secret_history", ROOT / "scripts/check-secret-history.py")
HISTORY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HISTORY)


class SecretHistoryReportTests(unittest.TestCase):
    def test_symlinked_report_parent_is_rejected_before_gitleaks(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as outside:
            root = Path(directory)
            external = Path(outside)
            sentinel = external / "preserve.txt"
            sentinel.write_text("preserve", encoding="utf-8")
            linked = root / "reports"
            linked.symlink_to(external, target_is_directory=True)
            report = linked / "history.json"

            with patch.object(HISTORY, "history_commits", return_value=[]), \
                    patch.object(HISTORY.subprocess, "run") as scanner:
                with self.assertRaisesRegex(ValueError, "report directory must not be a symlink"):
                    HISTORY.scan_history(root, "a" * 40, "b" * 40, report)

            scanner.assert_not_called()
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve")
            self.assertFalse(report.exists())


if __name__ == "__main__":
    unittest.main()
