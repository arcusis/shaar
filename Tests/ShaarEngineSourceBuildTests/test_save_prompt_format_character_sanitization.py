# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Strip Unicode format controls before serializing user-visible save details."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)
UNIT_TEST = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts_unittest.cc"
)


class SavePromptFormatCharacterSanitizationTests(unittest.TestCase):
    def test_format_controls_are_removed_and_regressions_are_covered(self):
        source = SOURCE.read_text()
        helper_start = source.index("bool IsFormatCharacter(")
        helper_end = source.index("bool HasOnlyKeys(", helper_start)
        helper = source[helper_start:helper_end]
        sanitizer_start = source.index("std::string SanitizeDetail(")
        sanitizer_end = source.index("bool OfferSavePrompt(", sanitizer_start)
        sanitizer = source[sanitizer_start:sanitizer_end]
        self.assertIn("code_point = (code_point << 6) | (continuation & 0x3F)", helper)
        self.assertIn("u_charType(static_cast<UChar32>(code_point)) == U_FORMAT_CHAR", helper)
        self.assertIn("IsFormatCharacter(raw, index, length)", sanitizer)
        self.assertLess(
            sanitizer.index("if (IsFormatCharacter(raw, index, length))"),
            sanitizer.index("cleaned.size() + length > kMaximumDetailBytes"),
        )
        unit_test = UNIT_TEST.read_text()
        self.assertIn("DetailDropsUnicodeFormattingControls", unit_test)
        self.assertIn('"user\\xE2\\x80\\xAE" "admin"', unit_test)
        self.assertIn("Repeat('a', 119) +", unit_test)
        self.assertIn('"\\xE2\\x80\\xAE" "b"', unit_test)
        self.assertIn('"soft\\xC2\\xAD" "hyphen"', unit_test)
        self.assertIn('"bom\\xEF\\xBB\\xBF" "text"', unit_test)


if __name__ == "__main__":
    unittest.main()
