# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Preserve the dismissal event contract used to clear native save bubbles."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptDismissalEnvelopeTests(unittest.TestCase):
    def test_dismissal_event_has_version_kind_id_and_original_scope(self):
        source = SOURCE.read_text()
        start = source.index("void EmitDismiss(")
        end = source.index("void Expire(", start)
        dismiss = source[start:end]

        self.assertIn('payload.Set("schemaVersion", 1)', dismiss)
        self.assertIn('payload.Set("kind", "savePromptDismissed")', dismiss)
        self.assertIn('payload.Set("id", request_id)', dismiss)
        self.assertIn("SHAAR_EVENT_SAVE_PROMPT", dismiss)
        self.assertIn("pending.profile_id", dismiss)
        self.assertIn("pending.window_id", dismiss)
        self.assertIn("pending.tab_id", dismiss)
        self.assertEqual(dismiss.count("payload.Set("), 3)


if __name__ == "__main__":
    unittest.main()
