# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Ensure delayed password decisions cannot target replacement credentials."""

from pathlib import Path
import hashlib
import json
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0116-shaar-password-save-prompt-snapshot.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"


class SavePromptPasswordSnapshotTests(unittest.TestCase):
    def test_decision_is_bound_to_the_offered_credentials(self):
        patch = PATCH.read_text()
        self.assertIn("const int prompt_generation = ++shaar_save_prompt_generation_;", patch)
        self.assertIn("int prompt_generation, int choice", patch)
        compare = patch.index("controller->shaar_save_prompt_generation_ != prompt_generation")
        state_read = patch.index("const auto current = controller->GetState()")
        self.assertLess(compare, state_read)
        self.assertIn("is_update, prompt_generation", patch)
        self.assertIn("int shaar_save_prompt_generation_ = 0;", patch)
        added_lines = "\n".join(
            line for line in patch.splitlines()
            if line.startswith("+") and not line.startswith("+++")
        )
        self.assertNotIn("password", added_lines)

    def test_password_snapshot_patch_is_pinned_with_its_content_hash(self):
        manifest = json.loads(MANIFEST.read_text())
        relative = str(PATCH.relative_to(ROOT))
        entries = [entry for entry in manifest["patches"] if entry["file"] == relative]
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["sha256"], hashlib.sha256(PATCH.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
