# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Ensure an invalid save choice leaves its request available to retry."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptInvalidChoiceTests(unittest.TestCase):
    def test_invalid_choice_returns_before_currentness_check_or_consumption(self):
        source = SOURCE.read_text()
        start = source.index("int TakeDecision(")
        end = source.index("bool ProfileOwnsContents(", start)
        take_decision = source[start:end]

        invalid_choice = take_decision.index("if (code == 0)")
        invalid_result = take_decision.index("*error = SHAAR_INVALID_ARGUMENT", invalid_choice)
        currentness_check = take_decision.index("if (!IsCurrent(found->second))")
        consume = take_decision.index("Finish(request_id, code)")
        self.assertLess(invalid_choice, invalid_result)
        self.assertLess(invalid_result, currentness_check)
        self.assertLess(currentness_check, consume)
        self.assertNotIn("Finish(request_id, kDecisionDismiss)", take_decision[invalid_choice:currentness_check])


if __name__ == "__main__":
    unittest.main()
