# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
BACKEND = REPO / "Sources/ChromiumBridge/ChromiumShaarBackend.mm"


class SecurityLoggingTests(unittest.TestCase):
    def test_lifecycle_diagnostics_do_not_log_engine_replies_or_errors(self):
        source = BACKEND.read_text()
        lifecycle = source[
            source.index("- (void)probeTabLifecycleForTabID:") : source.index("- (void)wakeTabID:")
        ]

        self.assertNotIn("reply=%@", lifecycle)
        self.assertNotIn("ShaarLifecycleFailureDescription", lifecycle)
        self.assertNotIn("localizedDescription", lifecycle)
        self.assertIn('NSLog(@"Shaar lifecycle probe failed (ABI %u)"', lifecycle)
        self.assertIn('NSLog(@"Shaar tab discard refused"', lifecycle)


if __name__ == "__main__":
    unittest.main()
