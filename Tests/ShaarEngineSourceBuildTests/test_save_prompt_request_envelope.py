# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Preserve the request envelope consumed by Shaar's native save bubble."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptRequestEnvelopeTests(unittest.TestCase):
    def test_offer_emits_versioned_request_with_all_native_fields(self):
        source = SOURCE.read_text()
        start = source.index("bool OfferSavePrompt(")
        end = source.index("shaar_error_code CompleteDecision(", start)
        offer = source[start:end]

        for field in (
            "schemaVersion",
            "kind",
            "id",
            "prompt",
            "origin",
            "pageURL",
            "detail",
            "update",
        ):
            with self.subTest(field=field):
                self.assertIn(f'payload.Set("{field}"', offer)
        self.assertEqual(offer.count("payload.Set("), 8)
        self.assertIn('payload.Set("schemaVersion", 1)', offer)
        self.assertIn('payload.Set("kind", "savePromptRequested")', offer)
        self.assertIn('payload.Set("detail", safe_detail)', offer)
        self.assertIn('SanitizeDetail(detail ? detail : "")', offer)
        self.assertIn("shaar::EmitEvent(", offer)
        self.assertIn("SHAAR_EVENT_SAVE_PROMPT", offer)


if __name__ == "__main__":
    unittest.main()
