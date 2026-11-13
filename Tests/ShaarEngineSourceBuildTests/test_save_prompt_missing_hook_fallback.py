# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Resolve pending Chromium save decisions if the optional engine hook is absent."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0066-shaar-save-prompts.patch"


class SavePromptMissingHookFallbackTests(unittest.TestCase):
    def test_each_hook_declines_when_the_weak_engine_symbol_is_missing(self):
        patch = PATCH.read_text()
        for prompt in ("password", "card", "address"):
            with self.subTest(prompt=prompt):
                hook = patch.index(f'OfferSavePrompt(web_contents(), "{prompt}"')
                branch = patch.rfind("if (shaar::save_prompts::OfferSavePrompt)", 0, hook)
                next_file = patch.find("\ndiff --git ", hook)
                self.assertNotEqual(branch, -1)
                region = patch[branch: next_file if next_file != -1 else None]
                self.assertIn("if (shaar::save_prompts::OfferSavePrompt)", region)
                self.assertIn("} else {", region)
                self.assertIn("std::move(decision).Run(2);", region)


if __name__ == "__main__":
    unittest.main()
