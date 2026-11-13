# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep successful save-prompt replies asynchronous on the engine sequence."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptAsyncReplyTests(unittest.TestCase):
    def test_reply_posts_delivery_instead_of_calling_back_inline(self):
        source = SOURCE.read_text()
        start = source.index("void Reply(const ReplyContext& request")
        end = source.index("shaar_error_code Fail(", start)
        reply = source[start:end]

        self.assertIn("PostTask(", reply)
        self.assertIn("base::BindOnce(&DeliverReply, request, SHAAR_OK", reply)
        self.assertNotIn("DeliverReply(request", reply)


if __name__ == "__main__":
    unittest.main()
