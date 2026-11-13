# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep native save prompts limited to local card-save offers."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0066-shaar-save-prompts.patch"


class SavePromptLocalCardScopeTests(unittest.TestCase):
    def test_card_hook_uses_local_callback_without_intercepting_upload_saves(self):
        source = PATCH.read_text()
        start = source.index(
            "diff --git a/chrome/browser/ui/autofill/payments/"
            "save_card_bubble_controller_impl.cc"
        )
        end = source.index(
            "diff --git a/chrome/browser/ui/autofill/chrome_autofill_client.cc",
            start,
        )
        card_patch = source[start:end]

        self.assertIn("LocalSaveCardPromptCallback", card_patch)
        self.assertIn("SetupLocalSave(card, options", card_patch)
        self.assertEqual(
            card_patch.count('OfferSavePrompt(web_contents(), "card"'), 1
        )
        self.assertNotIn("OfferUploadSave", card_patch)


if __name__ == "__main__":
    unittest.main()
