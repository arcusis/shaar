# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Route only pending password save states through the native prompt."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0066-shaar-save-prompts.patch"


class SavePromptPasswordStateScopeTests(unittest.TestCase):
    def test_other_password_bubbles_keep_the_chromium_path(self):
        source = PATCH.read_text()
        start = source.index("void ManagePasswordsUIController::ShowBubble()")
        end = source.index("diff --git a/chrome/browser/ui/autofill/payments/", start)
        password_hook = source[start:end]

        offer = password_hook.index('OfferSavePrompt(web_contents(), "password"')
        native_return = password_hook.index("    return;", offer)
        legacy_bubble = password_hook.index("ShowManagePasswordsBubble(user_action_)")
        self.assertIn("PENDING_PASSWORD_STATE", password_hook[:offer])
        self.assertIn("PENDING_PASSWORD_UPDATE_STATE", password_hook[:offer])
        self.assertLess(offer, native_return)
        self.assertLess(native_return, legacy_bubble)


if __name__ == "__main__":
    unittest.main()
