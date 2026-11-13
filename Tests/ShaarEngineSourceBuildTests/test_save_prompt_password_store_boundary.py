# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep saved passwords in Chromium and out of native prompt payloads."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0066-shaar-save-prompts.patch"


class SavePromptPasswordStoreBoundaryTests(unittest.TestCase):
    def test_save_uses_password_controller_and_prompt_receives_username_only(self):
        source = PATCH.read_text()
        start = source.index("void ManagePasswordsUIController::ShowBubble()")
        end = source.index(
            "diff --git a/chrome/browser/ui/autofill/payments/", start
        )
        password = source[start:end]

        self.assertIn("SavePassword(pending.username_value,", password)
        self.assertIn("pending.password_value);", password)
        offer_start = password.index(
            'OfferSavePrompt(web_contents(), "password"'
        )
        offer = password[offer_start:]
        offer = offer[:offer.index("std::move(decision)")]
        self.assertIn("detail.c_str(), is_update", offer)
        self.assertNotIn("password_value", offer)


if __name__ == "__main__":
    unittest.main()
