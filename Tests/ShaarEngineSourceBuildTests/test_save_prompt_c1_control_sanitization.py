# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep UTF-8 C1 controls out of native save prompt detail strings."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/shaar_save_prompts.cc"
UNIT_TEST = ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/shaar_save_prompts_unittest.cc"


class SavePromptC1ControlSanitizationTests(unittest.TestCase):
    def test_sanitizer_strips_c1_sequences_and_regresses_middle_and_terminal_cases(self):
        source = SOURCE.read_text()
        self.assertIn("if (lead == 0xC2 && index + 1 < raw.size())", source)
        self.assertIn("second >= 0x80 && second <= 0x9F", source)
        self.assertIn("index += 2;", source)
        tests = UNIT_TEST.read_text()
        self.assertIn('SanitizeDetail("a\\xC2\\x85" "b"), "ab"', tests)
        self.assertIn('SanitizeDetail("\\xC2\\x9F"), ""', tests)


if __name__ == "__main__":
    unittest.main()
