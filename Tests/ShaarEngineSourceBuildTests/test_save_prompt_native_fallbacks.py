# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep Chromium's native bubbles available outside Shaar embedder mode."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0066-shaar-save-prompts.patch"


class SavePromptNativeFallbackTests(unittest.TestCase):
    def test_embedder_hooks_keep_the_chromium_fallbacks(self):
        patch = PATCH.read_text()
        cases = (
            ('password', 'tab_dialogs->ShowManagePasswordsBubble(user_action_);'),
            ('card', '// If the confirmation view is still showing, close it before showing the new'),
            ('address', 'AddressBubblesController::SetUpAndShowSaveOrUpdateAddressBubble('),
        )
        for prompt, fallback in cases:
            with self.subTest(prompt=prompt):
                hook = patch.index(f'OfferSavePrompt(web_contents(), "{prompt}"')
                branch = patch.rfind('HasSwitch("shaar-embedder")', 0, hook)
                self.assertNotEqual(branch, -1)
                self.assertLess(branch, hook)
                return_at = patch.find("+    return;", hook)
                self.assertNotEqual(return_at, -1)
                fallback_at = patch.find(fallback, hook)
                self.assertNotEqual(fallback_at, -1)
                self.assertLess(hook, return_at)
                self.assertLess(return_at, fallback_at)
                next_file = patch.find('\ndiff --git ', hook)
                if next_file != -1:
                    self.assertLess(fallback_at, next_file)


if __name__ == "__main__":
    unittest.main()
