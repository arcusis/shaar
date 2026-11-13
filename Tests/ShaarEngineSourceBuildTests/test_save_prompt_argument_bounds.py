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
        self.assertIn("base::JSON_PARSE_RFC", parser)
        self.assertIn("!parsed || !parsed->is_dict()", parser)

    def test_decision_request_rejects_unknown_fields_and_control_identifiers(self):
        start = self.source.index("shaar_error_code CompleteDecision(")
        end = self.source.index("}  // namespace shaar::save_prompts", start)
        handler = self.source[start:end]
        self.assertIn('HasOnlyKeys(*args, {"schemaVersion", "id", "decision"})', handler)
        self.assertIn("!PlainIdentifier(*id)", handler)
        start = self.source.index("bool PlainIdentifier(")
        end = self.source.index("void Finish(", start)
        identifier = self.source[start:end]
        self.assertIn("id.size() > 128", identifier)
        self.assertIn("c < 32 || c == 127", identifier)


if __name__ == "__main__":
    unittest.main()
