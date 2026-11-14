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

    def test_escaped_wiki_markup_does_not_satisfy_index_membership(self):
        result = self.run_check({"_INDEX_Main.md": r"\[[One]]", "One.md": "# One"})
        self.assertEqual(result.returncode, 1)
        self.assertIn("Note not linked from any index: One.md", result.stderr)

    def test_unclosed_html_comment_does_not_link_remaining_notes(self):
        result = self.run_check({
            "_INDEX_Main.md": "[[Linked]]\n<!-- [[CommentedOut]]",
            "Linked.md": "", "CommentedOut.md": "",
        })
        self.assertEqual(result.returncode, 1)
        self.assertIn("Note not linked from any index: CommentedOut.md", result.stderr)

    def test_wrong_case_or_missing_target_does_not_count(self):
        result = self.run_check({"_INDEX_Main.md": "[[note]]\n[[Missing]]", "Note.md": ""})
        self.assertEqual(result.returncode, 1)
        self.assertIn("Note.md", result.stderr)

    def test_missing_index_target_fails_even_when_there_are_no_orphan_notes(self):
        result = self.run_check({"_INDEX_Main.md": "[[Missing_Note]]"})
        self.assertEqual(result.returncode, 1)
        self.assertIn("Broken Notebook index link: Missing_Note.md", result.stderr)

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

    def test_symlinked_note_cannot_satisfy_index_membership(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            notebook = root / "Notebook"
            notebook.mkdir()
            outside = root / "Outside.md"
            outside.write_text("# External note", encoding="utf-8")
            (notebook / "_INDEX_Main.md").write_text("[[Linked]]", encoding="utf-8")
            (notebook / "Linked.md").symlink_to(outside)
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--notebook", str(notebook)],
                cwd=directory, capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("Notebook contains symlink: Linked.md", result.stderr)

    def test_symlinked_notebook_root_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            notebook = root / "Notebook"
            notebook.mkdir()
            (notebook / "_INDEX_Main.md").write_text("[[Note]]", encoding="utf-8")
            (notebook / "Note.md").write_text("# Note", encoding="utf-8")
            linked = root / "linked-notebook"
            linked.symlink_to(notebook, target_is_directory=True)
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--notebook", str(linked)],
                cwd=directory, capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("Notebook root must not be a symlink", result.stderr)

    def test_notebook_prefix_in_nested_index_resolves_from_notebook_root(self):
        result = self.run_check({
            "_INDEX_Main.md": "[[nested/_INDEX_Nested]]",
            "nested/_INDEX_Nested.md": "[[Notebook/Target]]",
            "Target.md": "# Root target",
        })
        self.assertEqual(result.returncode, 0, result.stderr)
    def test_non_directory_notebook_argument_gets_a_direct_error(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "notebook.md"
            path.write_text("# Not a vault", encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--notebook", str(path)],
                cwd=directory, capture_output=True, text=True, check=False,
            )

            self.assertEqual(result.returncode, 1)
            self.assertIn("Notebook path is not a directory:", result.stderr)
            self.assertNotIn("No _INDEX_*.md files found", result.stderr)


if __name__ == "__main__":
    unittest.main()
