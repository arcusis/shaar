# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Register pending requests before exposing them to the native app."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptRegisterBeforeEventTests(unittest.TestCase):
    def test_pending_entry_exists_before_offer_event_can_be_decided(self):
        source = SOURCE.read_text()
        start = source.index("bool OfferSavePrompt(")
        end = source.index("shaar_error_code CompleteDecision(", start)
        offer = source[start:end]

        pending = offer.index("Pending().emplace(")
        event = offer.index("shaar::EmitEvent(", pending)
        self.assertLess(pending, event)
        self.assertIn("std::move(decision)", offer[pending:event])


if __name__ == "__main__":
    unittest.main()
