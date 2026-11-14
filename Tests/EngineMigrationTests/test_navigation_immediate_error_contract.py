# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class NavigationImmediateErrorContractTests(unittest.TestCase):
    def test_immediate_error_size_is_checked_before_decoding(self):
        source = (ROOT / "Sources/ShaarEngineABI/Navigation/NavigationAdapter.swift").read_text()
        failed_status = source.split("guard status == ShaarStatusCode.ok.rawValue else {", 1)[1].split(
            "\n    }", 1
        )[0]
        guard = "immediateError.size >= UInt32(MemoryLayout<shaar_error>.size)"
        self.assertIn(guard, failed_status)
        self.assertLess(failed_status.index(guard), failed_status.index("copyABISlice(immediateError.message)"))


if __name__ == "__main__":
    unittest.main()
