# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep address prompt decisions connected to profile save semantics."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0066-shaar-save-prompts.patch"


class SavePromptAddressDecisionMappingTests(unittest.TestCase):
    def test_accept_returns_profile_and_decline_returns_no_profile(self):
        source = PATCH.read_text()
        start = source.index(
            "diff --git a/chrome/browser/ui/autofill/chrome_autofill_client.cc"
        )
        address_hook = source[start:]
        start = address_hook.index("auto decision = base::BindOnce(")
        end = address_hook.index("if (shaar::save_prompts::OfferSavePrompt)", start)
        callback = address_hook[start:end]

        self.assertIn("if (choice == 1)", callback)
        self.assertIn("AddressPromptUserDecision::kAccepted", callback)
        self.assertIn(
            "Run(AddressPromptUserDecision::kAccepted,", callback
        )
        self.assertIn("saved);", callback)
        self.assertIn("AddressPromptUserDecision::kDeclined", callback)
        self.assertIn("std::nullopt", callback)


if __name__ == "__main__":
    unittest.main()
