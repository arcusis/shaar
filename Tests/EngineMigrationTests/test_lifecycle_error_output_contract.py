# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class LifecycleErrorOutputContractTests(unittest.TestCase):
    def test_error_size_is_checked_before_decoding_output_fields(self):
        source = (ROOT / "Sources/ShaarEngineABI/Lifecycle/ShaarLifecycleRuntime.swift").read_text()
        start = source.index("private static func decode(_ result: UInt32, error: ShaarLifecycleError) throws {")
        end = source.index("\n  }\n}", start)
        decoder = source[start:end]

        size_check = "error.size >= UInt32(MemoryLayout<ShaarLifecycleError>.size)"
        self.assertIn(size_check, decoder)
        for field in ("error.code", "error.platformCode", "error.message"):
            self.assertLess(decoder.index(size_check), decoder.index(field))


if __name__ == "__main__":
    unittest.main()
