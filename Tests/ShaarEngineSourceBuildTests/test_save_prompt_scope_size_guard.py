# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Validate save-prompt scope size before reading its fields."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptScopeSizeGuardTests(unittest.TestCase):
    def test_truncated_scope_is_rejected_before_selector_dereference(self):
        source = SOURCE.read_text()
        start = source.index("shaar_error_code CompleteDecision(")
        end = source.index("}  // namespace shaar::save_prompts", start)
        complete = source[start:end]

        size_guard = complete.index("scope.size < sizeof(shaar_scope)")
        error = complete.index('"invalid save prompt scope"', size_guard)
        selector = complete.index("scope.profile != nullptr", size_guard)
        self.assertLess(size_guard, selector)
        self.assertLess(selector, error)
        self.assertIn("SHAAR_INVALID_ARGUMENT", complete[selector:error])


if __name__ == "__main__":
    unittest.main()
