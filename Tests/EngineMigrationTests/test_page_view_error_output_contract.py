# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class PageViewErrorOutputContractTests(unittest.TestCase):
    def test_error_struct_size_is_checked_before_decoding_output_fields(self):
        source = (ROOT / "Sources/ShaarEngineABI/WindowsTabs/ShaarPageViewABI.swift").read_text()
        start = source.index("private func decode(_ status: shaar_error_code, error: shaar_error) throws {")
        end = source.index("\n  }\n}", start)
        decoder = source[start:end]

        size_check = "error.size >= UInt32(MemoryLayout<shaar_error>.size)"
        self.assertIn(size_check, decoder)
        for field in ("error.message.size", "error.message.data", "error.platform_code"):
            self.assertLess(decoder.index(size_check), decoder.index(field))


if __name__ == "__main__":
    unittest.main()
