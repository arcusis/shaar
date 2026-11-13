# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Reject direct save-prompt decisions scoped to private sessions."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptPrivateDecisionGuardTests(unittest.TestCase):
    def test_private_scope_is_rejected_before_tab_lookup_or_payload_parsing(self):
        source = SOURCE.read_text()
        start = source.index("shaar_error_code CompleteDecision(")
        end = source.index("}  // namespace shaar::save_prompts", start)
        complete = source[start:end]

        private = complete.index("if (scope.private_session)")
        error = complete.index("SHAAR_PRIVATE_DISALLOWED", private)
        tab_lookup = complete.index("FindWebContents(", private)
        payload_parse = complete.index("ParseArguments(bytes)", private)
        self.assertLess(private, error)
        self.assertLess(error, tab_lookup)
        self.assertLess(tab_lookup, payload_parse)


if __name__ == "__main__":
    unittest.main()
