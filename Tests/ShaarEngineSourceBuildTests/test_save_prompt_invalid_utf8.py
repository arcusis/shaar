# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Reject malformed UTF-8 before save-prompt details enter JSON payloads."""

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


class SavePromptInvalidUTF8Tests(unittest.TestCase):
    def test_sanitizer_validates_utf8_scalar_boundaries(self):
        source = SOURCE.read_text()
        start = source.index("bool IsValidUTF8Sequence(")
        end = source.index("std::string SanitizeDetail(", start)
        validator = source[start:end]
        for boundary in ("lead == 0xE0", "lead == 0xED", "lead == 0xF0", "lead == 0xF4"):
            self.assertIn(boundary, validator)
        self.assertIn("byte < 0x80 || byte > 0xBF", validator)
        self.assertIn("!IsValidUTF8Sequence(raw, index, length)", source)

    def test_cpp_regressions_cover_invalid_and_valid_multibyte_input(self):
        tests = UNIT_TEST.read_text()
        start = tests.index("TEST(ShaarSavePromptTest, DetailDropsMalformedUtf8Sequences)")
        end = tests.index("TEST(", start + 6)
        regression = tests[start:end]
        for sequence in (r"\xC0\xAF", r"\xED\xA0\x80", r"\xF4\x90\x80\x80", r"\xC3(", r"\xF0\x9F\x8C\x8D"):
            self.assertIn(sequence, regression)


if __name__ == "__main__":
    unittest.main()
