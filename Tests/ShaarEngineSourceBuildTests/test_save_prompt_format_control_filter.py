# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep Unicode format controls out of save prompt detail."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)
BUILD = ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/BUILD.gn"


class SavePromptFormatControlFilterTests(unittest.TestCase):
    def test_sanitizer_drops_unicode_format_characters(self):
        source = SOURCE.read_text()
        start = source.index("bool IsFormatCharacter(")
        end = source.index("bool HasOnlyKeys(", start)
        helper = source[start:end]
        self.assertIn("u_charType(static_cast<UChar32>(code_point)) == U_FORMAT_CHAR", helper)
        self.assertIn('"third_party/icu/source/common/unicode/uchar.h"', source)
        self.assertIn('"//third_party/icu:icuuc"', BUILD.read_text())


if __name__ == "__main__":
    unittest.main()
