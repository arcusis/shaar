# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of this file was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Report success only while an emitted offer remains pending."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptOfferResultTests(unittest.TestCase):
    def test_offer_success_requires_event_delivery_and_live_pending_entry(self):
        source = SOURCE.read_text()
        start = source.index("bool OfferSavePrompt(")
        end = source.index("shaar_error_code CompleteDecision(", start)
        offer = source[start:end]

        result = offer.index(
            "return emitted == SHAAR_OK && Pending().find(id) != Pending().end();"
        )
        event = offer.index("const shaar_error_code emitted = shaar::EmitEvent(")
        self.assertLess(event, result)
        self.assertIn("emitted == SHAAR_OK", offer[result:])
        self.assertIn("Pending().find(id) != Pending().end()", offer[result:])


if __name__ == "__main__":
    unittest.main()
