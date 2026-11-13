# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Resolve offers cleanly when request JSON serialization fails."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptSerializationFailureTests(unittest.TestCase):
    def test_serialization_failure_declines_before_pending_or_event(self):
        source = SOURCE.read_text()
        start = source.index("bool OfferSavePrompt(")
        end = source.index("shaar_error_code CompleteDecision(", start)
        offer = source[start:end]

        serialization = offer.index("if (!base::JSONWriter::Write(payload, &json))")
        decline = offer.index("return decline();", serialization)
        pending = offer.index("Pending().emplace(", serialization)
        event = offer.index("shaar::EmitEvent(", serialization)
        self.assertLess(serialization, decline)
        self.assertLess(decline, pending)
        self.assertLess(pending, event)


if __name__ == "__main__":
    unittest.main()
