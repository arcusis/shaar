# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Refuse save-prompt offers that cannot deliver a decision."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptCallbackRequiredTests(unittest.TestCase):
    def test_missing_decision_callback_returns_before_context_or_event(self):
        source = SOURCE.read_text()
        start = source.index("bool OfferSavePrompt(")
        end = source.index("shaar_error_code CompleteDecision(", start)
        offer = source[start:end]

        callback_guard = offer.index("if (!decision)")
        refusal = offer.index("return false;", callback_guard)
        context = offer.index("GetBrowserContext()", callback_guard)
        event = offer.index("shaar::EmitEvent(", callback_guard)
        self.assertLess(callback_guard, refusal)
        self.assertLess(refusal, context)
        self.assertLess(context, event)


if __name__ == "__main__":
    unittest.main()
