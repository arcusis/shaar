# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep local card save decisions mapped to Chromium's callback."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0066-shaar-save-prompts.patch"


class SavePromptCardDecisionMappingTests(unittest.TestCase):
    def test_save_accepts_and_decline_clears_the_local_card_offer(self):
        source = PATCH.read_text()
        start = source.index("diff --git a/chrome/browser/ui/autofill/payments/")
        end = source.index(
            "diff --git a/chrome/browser/ui/autofill/chrome_autofill_client.cc", start
        )
        card_hook = source[start:end]

        self.assertIn("if (choice == 1)", card_hook)
        self.assertIn("controller->OnSaveButton({})", card_hook)
        self.assertIn("SaveCardOfferUserDecision::", card_hook)
        self.assertIn("kDeclined", card_hook)
        self.assertIn(
            "controller->current_bubble_type_ = PaymentsBubbleType::kInactive",
            card_hook,
        )


if __name__ == "__main__":
    unittest.main()
