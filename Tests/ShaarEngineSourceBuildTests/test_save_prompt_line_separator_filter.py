# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep line separator controls from suppressing native save prompts."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptLineSeparatorFilterTests(unittest.TestCase):
    def test_sanitizer_drops_utf8_line_and_paragraph_separators(self):
        source = SOURCE.read_text()
        start = source.index("std::string SanitizeDetail(")
        end = source.index("bool OfferSavePrompt(", start)
        sanitizer = source[start:end]

        self.assertIn("lead == 0xE2", sanitizer)
        self.assertIn("raw[index + 1]) == 0x80", sanitizer)
        self.assertIn("separator == 0xA8 || separator == 0xA9", sanitizer)
        self.assertIn("index += 3", sanitizer)


if __name__ == "__main__":
    unittest.main()
