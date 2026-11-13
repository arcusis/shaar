# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Respect caller-sized error structs in save-prompt failures."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptErrorStructBoundsTests(unittest.TestCase):
    def test_failure_writes_only_error_fields_present_in_caller_size(self):
        source = SOURCE.read_text()
        start = source.index("shaar_error_code Fail(")
        end = source.index("std::optional<base::DictValue> ParseArguments(", start)
        fail = source[start:end]

        self.assertIn("if (error)", fail)
        self.assertIn("const uint32_t size = error->size", fail)
        for field in ("code", "platform_code", "message"):
            with self.subTest(field=field):
                self.assertIn(f"offsetof(shaar_error, {field})", fail)
                self.assertIn(f"sizeof(error->{field})", fail)
        self.assertIn("return code;", fail)


if __name__ == "__main__":
    unittest.main()
