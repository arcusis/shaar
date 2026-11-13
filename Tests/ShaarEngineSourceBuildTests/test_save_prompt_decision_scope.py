# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Protect the tab, profile, and page boundary for save prompt decisions."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
ENGINE_SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptDecisionScopeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = ENGINE_SOURCE.read_text()

    def test_decision_requires_the_original_engine_and_web_contents(self):
        start = self.source.index("int TakeDecision(")
        end = self.source.index("bool ProfileOwnsContents(", start)
        decision = self.source[start:end]
        self.assertIn("found->second.engine != engine", decision)
        self.assertIn("found->second.contents != contents", decision)
        self.assertIn("if (!IsCurrent(found->second))", decision)
        self.assertIn("Finish(request_id, kDecisionDismiss)", decision)

    def test_current_selection_must_match_tab_window_profile_and_page(self):
        start = self.source.index("bool IsCurrent(")
        end = self.source.index("int TakeDecision(", start)
        current = self.source[start:end]
        self.assertIn("FindSelectedRegularTab", current)
        self.assertIn("identity->window == pending.window", current)
        self.assertIn("identity->tab == pending.tab", current)
        self.assertIn("identity->profile_id == pending.profile_id", current)
        self.assertIn("identity->window_id == pending.window_id", current)
        self.assertIn("identity->tab_id == pending.tab_id", current)
        self.assertIn(
            "CleanPageURLForSavePrompt(pending.contents->GetLastCommittedURL()) ==", current
        )

    def test_decision_payload_rejects_unknown_fields_and_wrong_profile(self):
        self.assertIn(
            'HasOnlyKeys(*args, {"schemaVersion", "id", "decision"})', self.source
        )
        self.assertIn("ProfileOwnsContents(context, engine, scope, contents)", self.source)
        self.assertIn("SHAAR_WRONG_PROFILE", self.source)


if __name__ == "__main__":
    unittest.main()
