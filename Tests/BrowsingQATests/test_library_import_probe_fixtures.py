import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "engine_fixture", ROOT / "scripts/engine_fixture.py")
engine_fixture = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(engine_fixture)


class LibraryImportProbeFixturesTests(unittest.TestCase):
    def test_stages_chrome_and_safari_profile_exports(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            engine_fixture.prepare_library_import_fixtures(root)
            chrome = root / "library-import/chrome"
            safari = root / "library-import/safari"

            chrome_bookmarks = json.loads((chrome / "Bookmarks").read_text())
            self.assertEqual(
                chrome_bookmarks["roots"]["bookmark_bar"]["children"][0]["children"][0]["url"],
                "https://work.example.test/")
            with sqlite3.connect(chrome / "History") as database:
                self.assertEqual(
                    database.execute("SELECT url FROM urls WHERE id = 1").fetchone()[0],
                    "https://history.example.test/")

            self.assertTrue((safari / "Bookmarks.plist").is_file())
            with sqlite3.connect(safari / "History.db") as database:
                self.assertEqual(
                    database.execute("SELECT url FROM history_items WHERE id = 1").fetchone()[0],
                    "https://safari-history.example.test/")


if __name__ == "__main__":
    unittest.main()
