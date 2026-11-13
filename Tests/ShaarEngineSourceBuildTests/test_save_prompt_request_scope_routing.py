# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Route each save prompt to its originating profile, window, and tab."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptRequestScopeRoutingTests(unittest.TestCase):
    def test_request_event_uses_captured_profile_window_and_tab(self):
        source = SOURCE.read_text()
        start = source.index("bool OfferSavePrompt(")
        end = source.index("shaar_error_code CompleteDecision(", start)
        offer = source[start:end]
        emit = offer.index("const shaar_error_code emitted = shaar::EmitEvent(")
        event_call = offer[emit:]

        profile = event_call.index("{profile_id.data(), profile_id.size()}")
        empty_private = event_call.index("{},", profile)
        window = event_call.index("{window_id.data(), window_id.size()}", empty_private)
        tab = event_call.index("{tab_id.data(), tab_id.size()}", window)
        payload = event_call.index("{json.data(), json.size()}", tab)
        self.assertLess(profile, empty_private)
        self.assertLess(empty_private, window)
        self.assertLess(window, tab)
        self.assertLess(tab, payload)


if __name__ == "__main__":
    unittest.main()
