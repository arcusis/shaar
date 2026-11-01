# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "scripts/check-notebook-links.py"


class NotebookLinksTests(unittest.TestCase):
    def run_check(self, files):
        with tempfile.TemporaryDirectory() as directory:
            notebook = Path(directory) / "Notebook"
            notebook.mkdir()
            for name, text in files.items():
                path = notebook / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text, encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(SCRIPT), "--notebook", str(notebook)],
                cwd=directory, capture_output=True, text=True, check=False,
            )

    def test_links_from_any_index_accept_aliases_headings_and_extensions(self):
        result = self.run_check({
            "_INDEX_Main.md": "[[_INDEX_Browser]]\n[[One|First note]]",
            "_INDEX_Browser.md": "[[Two.md#Details]]\n[[Notebook/Three]]\n[[nested/Four]]",
            "One.md": "# One", "Two.md": "# Two", "Three.md": "# Three",
            "nested/Four.md": "# Four",
        })
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("4 notes, 2 indexes", result.stdout)

    def test_note_to_note_link_does_not_replace_index_membership(self):
        result = self.run_check({
            "_INDEX_Main.md": "[[One]]", "One.md": "[[Two]]", "Two.md": "# Two",
        })
        self.assertEqual(result.returncode, 1)
        self.assertIn("Note not linked from any index: Two.md", result.stderr)

    def test_comments_and_code_examples_do_not_hide_orphans(self):
        result = self.run_check({
            "_INDEX_Main.md": "<!-- [[One]] -->\n```md\n[[Two]]\n```\n~~~\n[[Three]]\n~~~\n`[[Four]]`",
            "One.md": "", "Two.md": "", "Three.md": "", "Four.md": "",
        })
        self.assertEqual(result.returncode, 1)
        for name in ("One", "Two", "Three", "Four"):
            self.assertIn(f"Note not linked from any index: {name}.md", result.stderr)

    def test_wrong_case_or_missing_target_does_not_count(self):
        result = self.run_check({"_INDEX_Main.md": "[[note]]\n[[Missing]]", "Note.md": ""})
        self.assertEqual(result.returncode, 1)
        self.assertIn("Note.md", result.stderr)

    def test_missing_indexes_fail_even_for_empty_notebook(self):
        for files in ({}, {"Note.md": "# Note"}):
            with self.subTest(files=files):
                result = self.run_check(files)
                self.assertEqual(result.returncode, 1)
                self.assertIn("No _INDEX_*.md files found", result.stderr)

    def test_renamed_note_requires_updated_index_link(self):
        result = self.run_check({"_INDEX_Main.md": "[[Old_Name]]", "New_Name.md": "# Renamed"})
        self.assertEqual(result.returncode, 1)
        self.assertIn("New_Name.md", result.stderr)


if __name__ == "__main__":
    unittest.main()
