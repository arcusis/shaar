# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Restrict save-prompt offers to supported kinds and update semantics."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptKindAllowlistTests(unittest.TestCase):
    def test_only_password_card_and_address_offers_are_accepted(self):
        source = SOURCE.read_text()
        start = source.index("bool KnownPrompt(")
        end = source.index("GURL OriginURL(", start)
        known_prompt = source[start:end]

        for kind in ("password", "card", "address"):
            with self.subTest(kind=kind):
                self.assertIn(f'"{kind}"', known_prompt)
        self.assertEqual(known_prompt.count("std::strcmp(prompt,"), 3)

    def test_unsupported_or_non_password_update_offers_dismiss_callback(self):
        source = SOURCE.read_text()
        start = source.index("bool OfferSavePrompt(")
        end = source.index("shaar_error_code CompleteDecision(", start)
        offer = source[start:end]
        guard = offer.index("!KnownPrompt(prompt) || (update && !password)")
        decline = offer.index("return decline();", guard)
        registry_access = offer.index("FindSelectedRegularTab", guard)
        self.assertLess(guard, decline)
        self.assertLess(decline, registry_access)
        self.assertIn("std::move(decision).Run(kDecisionDismiss)", offer)


if __name__ == "__main__":
    unittest.main()
