# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep save-prompt callback storage bounded under many tabs."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptPendingCapTests(unittest.TestCase):
    def test_offer_dismisses_instead_of_growing_pending_map_past_limit(self):
        source = SOURCE.read_text()
        self.assertIn("constexpr size_t kMaximumPending = 8;", source)
        start = source.index("bool OfferSavePrompt(")
        end = source.index("shaar_error_code CompleteDecision(", start)
        offer = source[start:end]

        replacement = offer.index("Supersede(contents)")
        cap_check = offer.index("Pending().size() >= kMaximumPending")
        decline = offer.index("return decline();", cap_check)
        insertion = offer.index("Pending().emplace(", cap_check)
        self.assertLess(replacement, cap_check)
        self.assertLess(cap_check, decline)
        self.assertLess(decline, insertion)


if __name__ == "__main__":
    unittest.main()
