# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Packaging retains only Shaar's supported Chromium localizations."""

import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "trim_engine_locales", ROOT / "scripts/trim-engine-locales.py")
TRIM = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TRIM)


class TrimEngineLocalesTests(unittest.TestCase):
    def test_main_refuses_current_symlink_that_redirects_outside_framework(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage = root / "stage"
            framework = stage / "Chromium Framework.framework"
            (framework / "Versions").mkdir(parents=True)
            external_resources = root / "outside" / "Resources"
            for locale in ("en", "he", "fr"):
                (external_resources / f"{locale}.lproj").mkdir(parents=True)
            current = framework / "Versions/Current"
            current.symlink_to(external_resources.parent, target_is_directory=True)

            with (patch.object(TRIM, "STAGE", stage),
                  patch.object(sys, "argv", ["trim-engine-locales.py", str(framework)]),
                  self.assertRaisesRegex(SystemExit, "outside the framework")):
                TRIM.main()

            self.assertTrue((external_resources / "fr.lproj").is_dir())

    def test_removed_byte_count_excludes_symlink_target_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            resources = root / "Resources"
            resources.mkdir()
            (resources / "en.lproj").mkdir()
            (resources / "he.lproj").mkdir()
            removed = resources / "fr.lproj"
            removed.mkdir()
            target = root / "outside.pak"
            target.write_bytes(b"not removed")
            (removed / "alias.pak").symlink_to(target)

            result = TRIM.trim_locales(resources)

            self.assertEqual(result["removedBytes"], 0)
            self.assertTrue(target.exists())

    def test_keeps_supported_languages_and_unrelated_resources(self):
        with tempfile.TemporaryDirectory() as temporary:
            resources = Path(temporary)
            for name in ("en", "en_FEMININE", "en_GB", "he", "he_NEUTER",
                         "fr", "fr_FEMININE", "ar"):
                localized = resources / f"{name}.lproj"
                localized.mkdir()
                (localized / "strings.pak").write_bytes(b"localization")
            (resources / "resources.pak").write_bytes(b"preserve")

            result = TRIM.trim_locales(resources)

            self.assertEqual(result["removedCount"], 3)
            self.assertEqual(result["removedBytes"], 3 * len(b"localization"))
            self.assertEqual(result["retained"], [
                "en.lproj", "en_FEMININE.lproj", "en_GB.lproj",
                "he.lproj", "he_NEUTER.lproj",
            ])
            self.assertEqual((resources / "resources.pak").read_bytes(), b"preserve")
            self.assertFalse((resources / "fr.lproj").exists())

    def test_missing_supported_language_fails_before_removing_anything(self):
        with tempfile.TemporaryDirectory() as temporary:
            resources = Path(temporary)
            (resources / "en.lproj").mkdir()
            (resources / "fr.lproj").mkdir()
            with self.assertRaisesRegex(ValueError, "he.lproj"):
                TRIM.trim_locales(resources)
            self.assertTrue((resources / "fr.lproj").exists())

    def test_symlinked_locale_fails_before_removing_anything(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            resources = root / "Resources"
            resources.mkdir()
            (resources / "en.lproj").mkdir()
            (resources / "he.lproj").mkdir()
            outside = root / "outside"
            outside.mkdir()
            (resources / "fr.lproj").symlink_to(outside, target_is_directory=True)

            with self.assertRaisesRegex(ValueError, "real directories: fr.lproj"):
                TRIM.trim_locales(resources)

            self.assertTrue((resources / "fr.lproj").is_symlink())
            self.assertTrue((resources / "en.lproj").is_dir())
            self.assertTrue(outside.is_dir())

    def test_resources_symlink_cannot_redirect_trimming_outside_stage(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage = root / "stage"
            framework = stage / "Chromium.framework"
            (framework / "Versions").mkdir(parents=True)
            external_resources = root / "external/Resources"
            external_resources.mkdir(parents=True)
            for name in ("en.lproj", "he.lproj", "fr.lproj"):
                (external_resources / name).mkdir()
            (framework / "Versions/Current").symlink_to(
                external_resources.parent, target_is_directory=True
            )
            with patch.object(TRIM, "STAGE", stage), patch(
                "sys.argv", ["trim-engine-locales.py", str(framework)]
            ):
                with self.assertRaisesRegex(SystemExit, "outside the framework"):
                    TRIM.main()
            self.assertTrue((external_resources / "fr.lproj").is_dir())


if __name__ == "__main__":
    unittest.main()
