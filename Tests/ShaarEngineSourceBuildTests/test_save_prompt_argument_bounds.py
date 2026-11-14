# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep save-prompt operation arguments bounded and identifier-safe."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptArgumentBoundsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SOURCE.read_text()

    def test_argument_parser_rejects_missing_empty_oversized_and_non_dict_json(self):
        start = self.source.index("std::optional<base::DictValue> ParseArguments(")
        end = self.source.index("bool HasOnlyKeys(", start)
        parser = self.source[start:end]
        self.assertIn("!bytes.data || bytes.size == 0", parser)
        self.assertIn("bytes.size > kMaximumArgumentsBytes", parser)
        self.assertIn("!parsed || !parsed->is_dict()", parser)

    def test_decision_request_rejects_unknown_fields_and_control_identifiers(self):
        start = self.source.index("shaar_error_code CompleteDecision(")
        end = self.source.index("}  // namespace shaar::save_prompts", start)
        handler = self.source[start:end]
        self.assertIn('HasOnlyKeys(*args, {"schemaVersion", "id", "decision"})', handler)
        self.assertIn("!IsValidDecisionRequestID(*id)", handler)

    def test_decision_ids_match_the_decimal_ids_emitted_by_the_engine(self):
        self.assertIn("std::to_string(++NextRequestID())", self.source)
        start = self.source.index("bool IsValidDecisionRequestID(")
        end = self.source.index("bool SavePromptAllowedForContext(", start)
        identifier = self.source[start:end]
        self.assertIn("id.size() > kMaximumDecisionRequestIDBytes", identifier)
        self.assertIn("constexpr size_t kMaximumDecisionRequestIDBytes = 20;", self.source)
        self.assertIn("c < '0' || c > '9'", identifier)


if __name__ == "__main__":
    unittest.main()
