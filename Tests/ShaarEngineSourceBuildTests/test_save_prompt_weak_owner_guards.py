# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Guard delayed save decisions after their owning UI controller is gone."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0066-shaar-save-prompts.patch"


class SavePromptWeakOwnerGuardTests(unittest.TestCase):
    def test_password_card_and_address_callbacks_check_weak_owners_first(self):
        source = PATCH.read_text()

        start = source.index("void ManagePasswordsUIController::ShowBubble()")
        end = source.index(
            "diff --git a/chrome/browser/ui/autofill/payments/", start
        )
        password = source[start:end]
        guard = password.index("if (!controller)")
        self.assertLess(guard, password.index("return;", guard))
        self.assertLess(password.index("return;", guard), password.index("controller->GetState()"))

        start = source.index(
            "diff --git a/chrome/browser/ui/autofill/payments/"
            "save_card_bubble_controller_impl.cc"
        )
        end = source.index(
            "diff --git a/chrome/browser/ui/autofill/chrome_autofill_client.cc",
            start,
        )
        card = source[start:end]
        guard = card.index("if (!controller)")
        self.assertLess(guard, card.index("return;", guard))
        self.assertLess(card.index("return;", guard), card.index("if (choice == 1)", guard))

        start = source.index(
            "diff --git a/chrome/browser/ui/autofill/chrome_autofill_client.cc"
        )
        address = source[start:]
        guard = address.index("if (!client || !callback)")
        self.assertLess(guard, address.index("return;", guard))
        self.assertLess(
            address.index("return;", guard), address.index("if (choice == 1)", guard)
        )


if __name__ == "__main__":
    unittest.main()
