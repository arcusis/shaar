# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep card callback supersession ahead of new controller state setup."""

from pathlib import Path
import hashlib
import json
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0115-shaar-card-save-prompt-supersede.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"
HEADER = ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/shaar_save_prompts.h"
SOURCE = ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/shaar_save_prompts.cc"


class SavePromptCardSupersedeTests(unittest.TestCase):
    def test_card_supersedes_old_callback_before_installing_new_state(self):
        patch = PATCH.read_text()
        call = patch.index("SupersedeSavePrompts(web_contents())")
        setup = patch.index("SetupLocalSave(card, options")
        self.assertLess(call, setup)
        self.assertIn("if (shaar::save_prompts::SupersedeSavePrompts)", patch)
        self.assertIn("void SupersedeSavePrompts(content::WebContents* contents);", HEADER.read_text())
        self.assertIn("Supersede(contents);", SOURCE.read_text())

    def test_followup_patch_is_pinned_with_its_content_hash(self):
        manifest = json.loads(MANIFEST.read_text())
        relative = str(PATCH.relative_to(ROOT))
        entries = [entry for entry in manifest["patches"] if entry["file"] == relative]
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["sha256"], hashlib.sha256(PATCH.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
