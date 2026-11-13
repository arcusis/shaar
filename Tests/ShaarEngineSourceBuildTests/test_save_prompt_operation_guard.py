# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Reject unknown operations before processing save-prompt scope or payload."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptOperationGuardTests(unittest.TestCase):
    def test_unknown_operation_fails_before_scope_validation(self):
        source = SOURCE.read_text()
        start = source.index("shaar_error_code CompleteDecision(")
        end = source.index("}  // namespace shaar::save_prompts", start)
        complete = source[start:end]

        operation = complete.index("operation != SHAAR_OP_SAVE_PROMPT_DECIDE")
        failure = complete.index('"unknown save prompt operation"', operation)
        scope = complete.index("scope.size < sizeof(shaar_scope)", operation)
        self.assertLess(operation, failure)
        self.assertLess(failure, scope)
        self.assertIn("SHAAR_INVALID_ARGUMENT", complete[operation:scope])


if __name__ == "__main__":
    unittest.main()
