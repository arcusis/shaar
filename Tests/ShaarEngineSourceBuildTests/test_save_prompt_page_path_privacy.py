# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep potentially sensitive URL paths inside Chromium."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/shaar_save_prompts.cc"


class SavePromptPagePathPrivacyTests(unittest.TestCase):
    def test_bridge_receives_only_origin_while_pending_state_keeps_full_page(self):
        source = SOURCE.read_text()
        start = source.index("bool OfferSavePrompt(")
        end = source.index("shaar_error_code CompleteDecision(", start)
        offer = source[start:end]
        self.assertIn('payload.Set("pageURL", origin.spec())', offer)
        self.assertNotIn('payload.Set("pageURL", page.spec())', offer)
        self.assertIn("PendingPrompt{engine, contents, window, tab, profile_id,", offer)
        self.assertIn("tab_id, prompt, page, update,", offer)


if __name__ == "__main__":
    unittest.main()
