# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep all three Chromium save offers wired to Shaar's embedder hook."""

from pathlib import Path
import hashlib
import json
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0066-shaar-save-prompts.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"


class SavePromptPatchTests(unittest.TestCase):
    def test_password_card_and_address_save_hooks_remain_present(self):
        source = PATCH.read_text()
        for kind in ("password", "card", "address"):
            with self.subTest(kind=kind):
                self.assertEqual(
                    source.count(f'OfferSavePrompt(web_contents(), "{kind}"'), 1
                )

        self.assertEqual(source.count('HasSwitch("shaar-embedder")'), 3)
        self.assertIn("GetPendingPassword().username_value", source)
        self.assertIn("card.NetworkAndLastFourDigits()", source)
        self.assertIn("append_field(NAME_FULL)", source)
        self.assertIn("append_field(ADDRESS_HOME_LINE1)", source)
        self.assertIn("append_field(ADDRESS_HOME_CITY)", source)

    def test_save_prompt_patch_is_pinned_in_source_build(self):
        manifest = json.loads(MANIFEST.read_text())
        relative = str(PATCH.relative_to(ROOT))
        matching = [entry for entry in manifest["patches"] if entry["file"] == relative]
        self.assertEqual(len(matching), 1)
        self.assertEqual(
            matching[0]["sha256"], hashlib.sha256(PATCH.read_bytes()).hexdigest()
        )


if __name__ == "__main__":
    unittest.main()
