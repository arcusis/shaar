# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Decline private-context offers before sending any save prompt event."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptPrivateOfferGuardTests(unittest.TestCase):
    def test_context_guard_precedes_registry_and_event_emission(self):
        source = SOURCE.read_text()
        start = source.index("bool OfferSavePrompt(")
        end = source.index("shaar_error_code CompleteDecision(", start)
        offer = source[start:end]

        context = offer.index("contents->GetBrowserContext()")
        guard = offer.index("SavePromptAllowedForContext(", context)
        decline = offer.index("return decline();", guard)
        registry = offer.index("FindSelectedRegularTab", guard)
        emission = offer.index("shaar::EmitEvent(", guard)
        self.assertLess(context, guard)
        self.assertLess(guard, decline)
        self.assertLess(decline, registry)
        self.assertLess(registry, emission)
        self.assertIn("browser_context->IsOffTheRecord()", offer[context:guard])


if __name__ == "__main__":
    unittest.main()
