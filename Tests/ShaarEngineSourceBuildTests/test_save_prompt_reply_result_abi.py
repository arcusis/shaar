# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Initialize and deliver the versioned result ABI for prompt decisions."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptReplyResultABITests(unittest.TestCase):
    def test_reply_initializes_result_and_error_sizes_before_callback(self):
        source = SOURCE.read_text()
        start = source.index("void DeliverReply(")
        end = source.index("void Reply(", start)
        deliver = source[start:end]

        result_size = deliver.index("result.size = sizeof(result)")
        error_size = deliver.index("result.error.size = sizeof(result.error)")
        callback = deliver.index("request.callback(request.context, &result)")
        self.assertLess(result_size, callback)
        self.assertLess(error_size, callback)
        self.assertIn("result.request_id = request.request_id", deliver[:callback])
        self.assertIn("result.error.code = code", deliver[:callback])
        self.assertIn("result.payload_json", deliver[:callback])


if __name__ == "__main__":
    unittest.main()
