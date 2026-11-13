# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep abandoned save prompt offers from retaining Chromium callbacks."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
ENGINE_SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptPendingLifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = ENGINE_SOURCE.read_text()

    def test_expired_offer_emits_dismissal_and_finishes_callback(self):
        start = self.source.index("void Expire(")
        end = self.source.index("void Supersede(", start)
        expire = self.source[start:end]
        self.assertIn("EmitDismiss(found->second, request_id)", expire)
        self.assertIn("Finish(request_id, kDecisionDismiss)", expire)

    def test_replacement_offer_dismisses_each_existing_request(self):
        start = self.source.index("void Supersede(")
        end = self.source.index("bool IsCurrent(", start)
        supersede = self.source[start:end]
        self.assertIn("pending.contents == contents", supersede)
        self.assertIn("EmitDismiss(found->second, id)", supersede)
        self.assertIn("Finish(id, kDecisionDismiss)", supersede)

    def test_delivery_failure_and_expiration_release_the_pending_entry(self):
        start = self.source.index("bool OfferSavePrompt(")
        end = self.source.index("shaar_error_code CompleteDecision(", start)
        offer = self.source[start:end]
        self.assertIn("Supersede(contents)", offer)
        self.assertIn("base::BindOnce(&Expire, id)", offer)
        self.assertIn("base::Minutes(2)", offer)
        self.assertIn("if (emitted != SHAAR_OK)", offer)
        self.assertIn("Finish(id, kDecisionDismiss)", offer)


if __name__ == "__main__":
    unittest.main()
