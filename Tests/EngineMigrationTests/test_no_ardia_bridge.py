# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ShaarOnlyBridgeTests(unittest.TestCase):
    def test_compiled_bridge_sources_have_no_ardia_dependency(self):
        for directory in ("Sources/ChromiumBridge", "Sources/ChromiumBridgeVerification"):
            for source in (ROOT / directory).rglob("*"):
                if source.suffix not in {".h", ".mm", ".m", ".cc", ".cpp"}:
                    continue
                with self.subTest(source=source.relative_to(ROOT)):
                    self.assertFalse("ArdiaCore" in source.read_text(), source.relative_to(ROOT))


if __name__ == "__main__":
    unittest.main()
