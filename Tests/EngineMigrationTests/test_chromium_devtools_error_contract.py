# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ChromiumDevToolsErrorContractTests(unittest.TestCase):
    def test_reply_validates_result_and_error_sizes_before_decoding(self):
        source = (ROOT / "Sources/ChromiumBridge/ChromiumDevTools.mm").read_text()
        start = source.index("[](void *context, const shaar_result *result) {")
        end = source.index("}, context, &error);", start)
        callback = source[start:end]

        result_size_check = "result->size < sizeof(*result)"
        error_size_check = "result->error.size < sizeof(result->error)"
        self.assertIn(result_size_check, callback)
        self.assertIn(error_size_check, callback)
        for check in (result_size_check, error_size_check):
            self.assertLess(callback.index(check), callback.index("result->error.code"))


if __name__ == "__main__":
    unittest.main()
