# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Preserve native save prompt gating and legacy UI fallback paths."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0066-shaar-save-prompts.patch"


class SavePromptEmbedderCompatibilityTests(unittest.TestCase):
    def test_each_prompt_is_embedder_gated_and_keeps_legacy_fallback(self):
        source = PATCH.read_text()

        password_start = source.index(
            "void ManagePasswordsUIController::ShowBubble()"
        )
        password_end = source.index(
            "diff --git a/chrome/browser/ui/autofill/payments/", password_start
        )
        password = source[password_start:password_end]
        password_gate = password.index('HasSwitch("shaar-embedder")')
        password_offer = password.index(
            'OfferSavePrompt(web_contents(), "password"'
        )
        password_return = password.index("    return;", password_offer)
        password_legacy = password.index("ShowManagePasswordsBubble(user_action_)")
        self.assertLess(password_gate, password_offer)
        self.assertLess(password_offer, password_return)
        self.assertLess(password_return, password_legacy)

        card_start = source.index(
            "diff --git a/chrome/browser/ui/autofill/payments/"
            "save_card_bubble_controller_impl.cc"
        )
        card_end = source.index(
            "diff --git a/chrome/browser/ui/autofill/chrome_autofill_client.cc",
            card_start,
        )
        card = source[card_start:card_end]
        card_gate = card.index('HasSwitch("shaar-embedder")')
        card_offer = card.index('OfferSavePrompt(web_contents(), "card"')
        card_return = card.index("    return;", card_offer)
        card_legacy = card.index("If the confirmation view is still showing", card_return)
        self.assertLess(card_gate, card_offer)
        self.assertLess(card_offer, card_return)
        self.assertLess(card_return, card_legacy)

        address_start = source.index(
            "diff --git a/chrome/browser/ui/autofill/chrome_autofill_client.cc"
        )
        address = source[address_start:]
        address_gate = address.index('HasSwitch("shaar-embedder")')
        address_offer = address.index('OfferSavePrompt(web_contents(), "address"')
        address_return = address.index("    return;", address_offer)
        address_legacy = address.index("AddressBubblesController::SetUpAndShow", address_return)
        self.assertLess(address_gate, address_offer)
        self.assertLess(address_offer, address_return)
        self.assertLess(address_return, address_legacy)


if __name__ == "__main__":
    unittest.main()
