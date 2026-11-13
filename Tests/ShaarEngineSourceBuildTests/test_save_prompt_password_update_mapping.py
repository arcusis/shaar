# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Preserve password-update-specific save prompt decisions."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0066-shaar-save-prompts.patch"


class SavePromptPasswordUpdateMappingTests(unittest.TestCase):
    def test_updates_cannot_disable_saving_and_dismiss_with_update_callback(self):
        source = PATCH.read_text()
        start = source.index("void ManagePasswordsUIController::ShowBubble()")
        end = source.index("diff --git a/chrome/browser/ui/autofill/payments/", start)
        password_hook = source[start:end]

        self.assertIn("choice == 3 && !update", password_hook)
        self.assertIn("OnNotNowClicked()", password_hook)
        self.assertIn("OnNopeUpdateClicked()", password_hook)
        self.assertIn("PENDING_PASSWORD_UPDATE_STATE", password_hook)
        self.assertIn('OfferSavePrompt(web_contents(), "password"', password_hook)
        self.assertIn("detail.c_str(), is_update", password_hook)


if __name__ == "__main__":
    unittest.main()
