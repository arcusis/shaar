# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class StorageKeychainNestedErrorContractTests(unittest.TestCase):
    def test_result_error_size_is_checked_before_reading_error_fields(self):
        source = (ROOT / "Sources/ShaarEngineABI/StorageKeychain/"
                  "ShaarStorageKeychainABITransport.swift").read_text()
        start = source.index("private let storageKeychainReply:")
        end = source.index("\n/// Concrete profile-only", start)
        callback = source[start:end]

        size_check = "result.error.size >= UInt32(MemoryLayout<shaar_error>.size)"
        self.assertIn(size_check, callback)
        for field in ("result.error.message", "result.error.code", "result.error.platform_code"):
            self.assertLess(callback.index(size_check), callback.index(field))


if __name__ == "__main__":
    unittest.main()
