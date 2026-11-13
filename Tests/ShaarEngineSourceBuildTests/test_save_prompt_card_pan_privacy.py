# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep full payment card numbers out of native save prompt events."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0066-shaar-save-prompts.patch"


class SavePromptCardPANPrivacyTests(unittest.TestCase):
    def test_event_detail_is_network_and_last_four_not_full_pan(self):
        source = PATCH.read_text()
        start = source.index(
            "diff --git a/chrome/browser/ui/autofill/payments/"
            "save_card_bubble_controller_impl.cc"
        )
        end = source.index(
            "diff --git a/chrome/browser/ui/autofill/chrome_autofill_client.cc",
            start,
        )
        card = source[start:end]

        detail = card.index("base::UTF16ToUTF8(card.NetworkAndLastFourDigits())")
        offer = card.index('OfferSavePrompt(web_contents(), "card"', detail)
        self.assertIn("detail.c_str()", card[offer:])
        self.assertNotIn("card.number()", card)
        self.assertNotIn("CREDIT_CARD_NUMBER", card)


if __name__ == "__main__":
    unittest.main()
