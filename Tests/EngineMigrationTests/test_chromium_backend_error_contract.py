# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ChromiumBackendErrorContractTests(unittest.TestCase):
    def test_result_callbacks_validate_before_reading_result_fields(self):
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


if __name__ == "__main__":
    unittest.main()
