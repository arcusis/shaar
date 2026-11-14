# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of this file was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Clean pending save prompts when expiry scheduling fails."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptExpiryScheduleFailureTests(unittest.TestCase):
    def test_failed_expiry_schedule_dismisses_before_emitting_offer(self):
        source = SOURCE.read_text()
        start = source.index("bool OfferSavePrompt(")
        end = source.index("shaar_error_code CompleteDecision(", start)
        offer = source[start:end]

        scheduled = offer.index("const bool expiry_scheduled =")
        failure = offer.index("if (!expiry_scheduled)", scheduled)
        finish = offer.index("Finish(id, kDecisionDismiss)", failure)
        early_return = offer.index("return false;", finish)
        event = offer.index("shaar::EmitEvent(", failure)
        self.assertLess(scheduled, failure)
        self.assertLess(failure, finish)
        self.assertLess(finish, early_return)
        self.assertLess(early_return, event)


if __name__ == "__main__":
    unittest.main()
