# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Require exactly one save-prompt scope selector."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptScopeShapeTests(unittest.TestCase):
    def test_missing_or_ambiguous_scope_is_rejected_before_private_handling(self):
        source = SOURCE.read_text()
        start = source.index("shaar_error_code CompleteDecision(")
        end = source.index("}  // namespace shaar::save_prompts", start)
        complete = source[start:end]

        shape = complete.index(
            "(scope.profile != nullptr) == (scope.private_session != nullptr)"
        )
        invalid = complete.index('"invalid save prompt scope"', shape)
        private = complete.index("if (scope.private_session)", shape)
        tab_lookup = complete.index("FindWebContents(", private)
        self.assertLess(shape, invalid)
        self.assertLess(invalid, private)
        self.assertLess(private, tab_lookup)
        self.assertIn("SHAAR_INVALID_ARGUMENT", complete[shape:private])


if __name__ == "__main__":
    unittest.main()
