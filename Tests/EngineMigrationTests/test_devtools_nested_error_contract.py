# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class DevToolsNestedErrorContractTests(unittest.TestCase):
    def test_error_struct_size_is_checked_before_decoding_error_fields(self):
        source = (ROOT / "Sources/ShaarEngineABI/DevTools/DevToolsAdapter.swift").read_text()
        start = source.index("private let shaarDevToolsABICallback:")
        end = source.index("\n/// Concrete transport", start)
        callback = source[start:end]

        size_check = "value.error.size >= UInt32(MemoryLayout<shaar_error>.size)"
        self.assertIn(size_check, callback)
        for field in ("value.error.code", "value.error.platform_code", "value.error.message"):
            self.assertLess(callback.index(size_check), callback.index(field))


if __name__ == "__main__":
    unittest.main()
