# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep failed save-prompt decisions out of the success reply path."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptErrorReplyBoundaryTests(unittest.TestCase):
    def test_decision_errors_return_before_success_reply_is_scheduled(self):
        source = SOURCE.read_text()
        start = source.index("shaar_error_code CompleteDecision(")
        end = source.index("}  // namespace shaar::save_prompts", start)
        complete = source[start:end]

        error = complete.index("if (resolved != SHAAR_OK)")
        failure_return = complete.index("return Fail(immediate_error, resolved, message)", error)
        reply = complete.index("Reply({request_id, reply, reply_context}", error)
        self.assertLess(error, failure_return)
        self.assertLess(failure_return, reply)


if __name__ == "__main__":
    unittest.main()
