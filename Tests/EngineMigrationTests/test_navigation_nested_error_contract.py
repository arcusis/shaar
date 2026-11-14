# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class NavigationNestedErrorContractTests(unittest.TestCase):
    def test_error_struct_size_is_checked_before_decoding_error_fields(self):
        source = (ROOT / "Sources/ShaarEngineABI/Navigation/NavigationAdapter.swift").read_text()
        start = source.index("private let shaarNavigationReply:")
        end = source.index("\nprivate final class ShaarNavigationRequestIDs", start)
        callback = source[start:end]

        size_check = "result.error.size >= UInt32(MemoryLayout<shaar_error>.size)"
        self.assertIn(size_check, callback)
        for field in ("result.error.code", "result.error.platform_code", "result.error.message"):
            self.assertLess(callback.index(size_check), callback.index(field))


if __name__ == "__main__":
    unittest.main()
