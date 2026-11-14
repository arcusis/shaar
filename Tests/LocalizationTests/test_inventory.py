# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Catalog-only gates, on-demand exports, and independent string additions."""

import contextlib
import csv
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("check_localization", ROOT / "scripts/check-localization.py")
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)
VALIDATOR = CHECK.load_validator()


def entry(value):
    return {"localizations": {"he": {"stringUnit": {"state": "translated", "value": value}}}}


class InventoryTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.catalog = self.root / "Sources/BrowserCore/Resources/Core.xcstrings"
        self.catalog.parent.mkdir(parents=True)
        self.write_catalog({"Open %@": entry("פתחי %@")})
        files = {
            "Sources/BrowserCore/View.swift": 'BrowserLocalization.string("Open %@")\n',
            "Sources/BrowserCore/ProductIdentity.swift":
                'return "Shaar"\nreturn "Arcusis Browser"\n',
            "Sources/BrowserCore/BrowserSession.swift":
                'name = try values.decode(String.self, forKey: .name)\n',
            "Resources/ExtensionManager/manager.html": '<title>Shaar Extension Manager</title>\n',
            "Resources/ExtensionManager/manifest.json": '{"name": "Shaar Extension Manager"}\n',
            "Sources/ChromiumBridge/ChromiumExtensions.mm":
                'return info ? [self shaarExtensionPopupViewForID:popupID windowID:info[@"windowID"]] : nil;\n',
        }
        for name, text in files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        root_patch = patch.object(CHECK, "ROOT", self.root)
        validator_patch = patch.object(CHECK, "load_validator", return_value=VALIDATOR)
        self.addCleanup(root_patch.stop)
        self.addCleanup(validator_patch.stop)
        root_patch.start()
        validator_patch.start()

    def write_catalog(self, strings):
        self.catalog.write_text(json.dumps({"sourceLanguage": "en", "strings": strings},
                                           ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    def run_check(self, *arguments):
        with patch("sys.argv", ["check-localization.py", *map(str, arguments)]), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            return CHECK.main()

    def test_gate_needs_no_inventory_and_ignores_stale_copies(self):
        with patch.object(CHECK, "inventory_rows", side_effect=AssertionError("export was not requested")):
            self.assertEqual(self.run_check(), 0)
            self.assertFalse((self.root / "build").exists())
            for name in ("Notebook/Hebrew_String_Inventory.csv", "build/Localization/Hebrew_String_Inventory.csv"):
                path = self.root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("stale", encoding="utf-8")
            self.assertEqual(self.run_check(), 0)

    def test_gate_and_export_reject_missing_hebrew_and_wrong_placeholders(self):
        for value in ({"localizations": {}}, entry("פתחי %d")):
            self.write_catalog({"Open %@": value})
            for arguments in ((), ("--write-inventory",)):
                with self.subTest(value=value, arguments=arguments):
                    self.assertEqual(self.run_check(*arguments), 1)
                    self.assertFalse((self.root / "build").exists())

    def test_gate_still_rejects_unknown_source_keys(self):
        (self.root / "Sources/BrowserCore/View.swift").write_text(
            'BrowserLocalization.string("Untranslated")\n', encoding="utf-8")
        self.assertEqual(self.run_check(), 1)

    def test_exports_reproducible_csv_to_ignored_build_directory_or_selected_path(self):
        self.assertEqual(self.run_check("--write-inventory"), 0)
        output = self.root / "build/Localization/Hebrew_String_Inventory.csv"
        expected = output.read_bytes()
        rows = list(csv.DictReader(io.StringIO(expected.decode("utf-8"))))
        translated = next(row for row in rows if row["key"] == "Open %@")
        self.assertEqual(json.loads(translated["hebrew"]), {"other": "פתחי %@"})
        self.assertEqual(translated["source_file"], "Sources/BrowserCore/View.swift")
        self.assertEqual(translated["source_line"], "1")
        self.assertTrue(any(row["disposition"] == "retained product brand" for row in rows))
        self.assertTrue(any(row["key"] == "Extension popup visibility boundary" and
                            row["english"] == "engine-owned popup view" for row in rows))
        self.assertFalse((self.root / "Notebook/Hebrew_String_Inventory.csv").exists())
        self.assertEqual(self.run_check("--write-inventory"), 0)
        self.assertEqual(output.read_bytes(), expected)
        custom = self.root / "artifacts/translators/strings.csv"
        self.assertEqual(self.run_check("--write-inventory", custom), 0)
        self.assertEqual(custom.read_bytes(), expected)

    def test_export_write_failure_fails_gate(self):
        destination = self.root / "not-a-directory"
        destination.write_text("file", encoding="utf-8")
        self.assertEqual(self.run_check("--write-inventory", destination / "inventory.csv"), 1)

    def test_export_rejects_symlink_without_overwriting_target(self):
        target = self.root / "existing.csv"
        target.write_text("preserve this report", encoding="utf-8")
        destination = self.root / "inventory.csv"
        destination.symlink_to(target)

        self.assertEqual(self.run_check("--write-inventory", destination), 1)
        self.assertEqual(target.read_text(encoding="utf-8"), "preserve this report")
    def test_inventory_export_rejects_symlink_before_overwriting_target(self):
        target = self.root / "outside.csv"
        target.write_text("preserve this", encoding="utf-8")
        output = self.root / "inventory.csv"
        output.symlink_to(target)

        self.assertEqual(self.run_check("--write-inventory", output), 1)
        self.assertEqual(target.read_text(encoding="utf-8"), "preserve this")

    def test_independent_string_additions_merge_and_pass_without_inventory(self):
        strings = {"Open %@": entry("פתחי %@"),
                   **{f"Middle {index}": entry(f"אמצע {index}") for index in range(6)}}
        self.write_catalog(strings)
        base = self.root / "base.xcstrings"
        base.write_bytes(self.catalog.read_bytes())
        self.write_catalog({"First %@": entry("ראשון %@"), **strings})
        first = self.catalog.read_bytes()
        self.assertEqual(self.run_check(), 0)
        self.write_catalog({**strings, "Last %d": entry("אחרון %d")})
        second = self.root / "second.xcstrings"
        second.write_bytes(self.catalog.read_bytes())
        self.assertEqual(self.run_check(), 0)
        self.catalog.write_bytes(first)
        merged = subprocess.run(["git", "merge-file", "-p", str(self.catalog), str(base), str(second)],
                                capture_output=True, check=False)
        self.assertEqual(merged.returncode, 0, merged.stderr.decode())
        self.catalog.write_bytes(merged.stdout)
        self.assertEqual(self.run_check(), 0)
        keys = json.loads(self.catalog.read_text())["strings"]
        self.assertIn("First %@", keys)
        self.assertIn("Last %d", keys)
        self.assertFalse((self.root / "build").exists())


if __name__ == "__main__":
    unittest.main()
