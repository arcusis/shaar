# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Reject incomplete save-prompt operation handles before tab lookup."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptRequiredArgumentsTests(unittest.TestCase):
    def test_missing_context_handles_or_reply_is_invalid_before_lookup(self):
        source = SOURCE.read_text()
        start = source.index("shaar_error_code CompleteDecision(")
        end = source.index("}  // namespace shaar::save_prompts", start)
        complete = source[start:end]

        required = complete.index(
            "if (!context || !context->browser_tabs || !window || !tab || "
            "!reply ||"
        )
        request_id = complete.index("!request_id", required)
        error = complete.index('"save prompt tab is missing"', required)
        lookup = complete.index("FindWebContents(", required)
        self.assertLess(request_id, error)
        self.assertLess(required, error)
        self.assertLess(error, lookup)
        self.assertIn("SHAAR_INVALID_ARGUMENT", complete[required:lookup])


if __name__ == "__main__":
    unittest.main()
