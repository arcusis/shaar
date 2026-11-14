# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ChromiumBridgeErrorContractTests(unittest.TestCase):
    def test_backend_result_callbacks_validate_before_reading_fields(self):
        source = (ROOT / "Sources/ChromiumBridge/ChromiumShaarBackend.mm").read_text()
        marker = "[](void *context, const shaar_result *result) {"
        callbacks = source.split(marker)[1:]
        self.assertEqual(len(callbacks), 4)

        for callback in callbacks:
            callback = callback[:callback.index("}, context, &")]
            validation = callback.find("ShaarResultIsValid(result)")
            member_reads = [
                position for token in ("result->error.code", "result->payload_json")
                if (position := callback.find(token)) >= 0
            ]
            self.assertGreaterEqual(validation, 0)
            self.assertTrue(member_reads)
            self.assertLess(validation, min(member_reads))

    def test_private_reply_checks_result_and_error_sizes_before_decoding(self):
        source = (ROOT / "Sources/ChromiumBridge/ChromiumShaarPrivateSupport.mm").read_text()
        start = source.index("void Reply(void *context, const shaar_result *result) {")
        end = source.index("\n}\n}  // namespace", start)
        callback = source[start:end]

        result_size_check = "result->size < sizeof(*result)"
        error_size_check = "result->error.size < sizeof(result->error)"
        self.assertIn(result_size_check, callback)
        self.assertIn(error_size_check, callback)
        self.assertLess(callback.index(result_size_check), callback.index("result->error.code"))
        self.assertLess(callback.index(error_size_check), callback.index("result->error.code"))

    def test_feature_reply_checks_result_and_error_sizes_before_decoding(self):
        source = (ROOT / "Sources/ChromiumBridge/ChromiumShaarFeatureTransport.inc").read_text()
        start = source.index("[](void *context, const shaar_result *result) {")
        end = source.index("}, context, &error);", start)
        callback = source[start:end]

        result_size_check = "result->size < sizeof(*result)"
        error_size_check = "result->error.size < sizeof(result->error)"
        self.assertIn(result_size_check, callback)
        self.assertIn(error_size_check, callback)
        self.assertLess(callback.index(result_size_check), callback.index("result->error.code"))
        self.assertLess(callback.index(error_size_check), callback.index("result->error.code"))

    def test_devtools_reply_checks_result_and_error_sizes_before_decoding(self):
        source = (ROOT / "Sources/ChromiumBridge/ChromiumDevTools.mm").read_text()
        start = source.index("[](void *context, const shaar_result *result) {")
        end = source.index("}, context, &error);", start)
        callback = source[start:end]

        result_size_check = "result->size < sizeof(*result)"
        error_size_check = "result->error.size < sizeof(result->error)"
        self.assertIn(result_size_check, callback)
        self.assertIn(error_size_check, callback)
        self.assertLess(callback.index(result_size_check), callback.index("result->error.code"))
        self.assertLess(callback.index(error_size_check), callback.index("result->error.code"))


if __name__ == "__main__":
    unittest.main()
