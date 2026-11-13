# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Preserve the decision reply consumed by the native save prompt store."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptDecisionReplyEnvelopeTests(unittest.TestCase):
    def test_success_reply_contains_version_and_decision_name(self):
        source = SOURCE.read_text()
        start = source.index("const char* DecisionName(")
        end = source.index("bool KnownPrompt(", start)
        decision_name = source[start:end]
        self.assertIn('return "save";', decision_name)
        self.assertIn('return "never";', decision_name)
        self.assertIn('return "dismiss";', decision_name)

        start = source.index("shaar_error_code CompleteDecision(")
        end = source.index("}  // namespace shaar::save_prompts", start)
        complete = source[start:end]
        schema = complete.index('result.Set("schemaVersion", 1)')
        decision = complete.index('result.Set("decision", DecisionName(code))', schema)
        reply = complete.index("Reply({request_id, reply, reply_context}", decision)
        self.assertLess(schema, decision)
        self.assertLess(decision, reply)


if __name__ == "__main__":
    unittest.main()
