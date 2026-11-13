# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Limit save-prompt offers to selected registered regular tabs."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptActiveTabOfferGuardTests(unittest.TestCase):
    def test_offer_requires_registered_tab_identity_before_emitting(self):
        source = SOURCE.read_text()
        start = source.index("bool OfferSavePrompt(")
        end = source.index("shaar_error_code CompleteDecision(", start)
        offer = source[start:end]

        lookup = offer.index("FindSelectedRegularTab(engine, contents)")
        missing_identity = offer.index("!identity", lookup)
        profile_id = offer.index("identity->profile_id.empty()", lookup)
        window_id = offer.index("identity->window_id.empty()", profile_id)
        tab_id = offer.index("identity->tab_id.empty()", window_id)
        decline = offer.index("return decline();", tab_id)
        emission = offer.index("shaar::EmitEvent(", lookup)
        self.assertLess(lookup, missing_identity)
        self.assertLess(missing_identity, profile_id)
        self.assertLess(profile_id, window_id)
        self.assertLess(window_id, tab_id)
        self.assertLess(tab_id, decline)
        self.assertLess(decline, emission)


if __name__ == "__main__":
    unittest.main()
