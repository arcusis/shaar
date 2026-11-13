# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep account-migration address offers on Chromium's dedicated flow."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0066-shaar-save-prompts.patch"


class SavePromptAddressMigrationFallbackTests(unittest.TestCase):
    def test_account_migration_offer_bypasses_generic_native_prompt(self):
        source = PATCH.read_text()
        start = source.index("if (save_address_bubble_type !=")
        end = source.index("AddressBubblesController::SetUpAndShow", start)
        address_hook = source[start:end]

        self.assertIn(
            "save_address_bubble_type != SaveAddressBubbleType::kMigrateToAccount",
            address_hook,
        )
        self.assertIn('OfferSavePrompt(web_contents(), "address"', address_hook)
        self.assertIn("AddressBubblesController::SetUpAndShow", source[end:])


if __name__ == "__main__":
    unittest.main()
