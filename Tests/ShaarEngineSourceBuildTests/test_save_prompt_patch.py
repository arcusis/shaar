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
ENGINE_SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


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

    def test_save_prompt_layer_and_decision_operation_are_registered(self):
        block = json.loads(MANIFEST.read_text())["moduleBlocks"]["save_prompts"]
        self.assertEqual(block["operationRange"], [1500, 1500])
        self.assertEqual(block["moduleID"], 1500)
        self.assertIn(
            "chrome/browser/shaar/save_prompts/shaar_save_prompts.cc",
            block["layerFiles"],
        )
        self.assertIn(
            "chrome/browser/shaar/save_prompts/shaar_save_prompts_unittest.cc",
            block["layerFiles"],
        )

    def test_save_prompt_page_url_drops_credentials_query_and_fragment(self):
        source = ENGINE_SOURCE.read_text()
        self.assertIn("!url.SchemeIsHTTPOrHTTPS()", source)
        self.assertIn("replacements.ClearUsername()", source)
        self.assertIn("replacements.ClearPassword()", source)
        self.assertIn("replacements.ClearQuery()", source)
        self.assertIn("replacements.ClearRef()", source)
        self.assertIn(
            "const GURL page = CleanPageURLForSavePrompt(contents->GetLastCommittedURL());", source
        )
        self.assertIn('payload.Set("pageURL", origin.spec())', source)
        self.assertIn('payload.Set("origin", origin.spec())', source)


if __name__ == "__main__":
    unittest.main()
