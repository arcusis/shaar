# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep engine save prompt details compatible with native Unicode validation."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptC1ControlFilterTests(unittest.TestCase):
    def test_sanitizer_drops_utf8_c1_controls(self):
        source = SOURCE.read_text()
        start = source.index("std::string SanitizeDetail(")
        end = source.index("bool OfferSavePrompt(", start)
        sanitizer = source[start:end]

        self.assertIn("lead == 0xC2", sanitizer)
        self.assertIn("continuation >= 0x80 && continuation <= 0x9F", sanitizer)
        self.assertIn("index += 2", sanitizer)


if __name__ == "__main__":
    unittest.main()
