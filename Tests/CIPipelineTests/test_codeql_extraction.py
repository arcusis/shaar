# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "check_codeql_extraction", ROOT / "scripts/check-codeql-extraction.py"
)
EXTRACTION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EXTRACTION)


class CodeQLExtractionTests(unittest.TestCase):
    def test_coverage_writer_rejects_symlinked_parent_without_touching_target(self):
        with tempfile.TemporaryDirectory() as temporary, tempfile.TemporaryDirectory() as outside:
            root = Path(temporary)
            external = Path(outside)
            sentinel = external / "keep.txt"
            sentinel.write_text("preserve", encoding="utf-8")
            linked = root / "linked"
            linked.symlink_to(external, target_is_directory=True)

            with self.assertRaisesRegex(ValueError, "output directory must not be a symlink"):
                EXTRACTION.write_coverage_report(linked / "extraction.json", {"missing": []})

            self.assertEqual(sentinel.read_text(encoding="utf-8"), "preserve")
            self.assertFalse((external / "coverage.json").exists())


if __name__ == "__main__":
    unittest.main()
