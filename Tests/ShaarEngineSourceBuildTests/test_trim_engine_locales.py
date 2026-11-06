# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Packaging retains only Shaar's supported Chromium localizations."""

import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "trim_engine_locales", ROOT / "scripts/trim-engine-locales.py")
TRIM = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TRIM)


class TrimEngineLocalesTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
