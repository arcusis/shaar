# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
BACKEND = REPO / "Sources/ChromiumBridge/ChromiumShaarBackend.mm"
ENGINE_ABI = REPO / "Sources/ShaarEngineABI/ShaarEngineABI.swift"


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

    def test_event_rejection_does_not_log_engine_error_details(self):
        source = ENGINE_ABI.read_text()
        dispatcher = source[
            source.index("@MainActor public final class ShaarEventDispatcher") :
            source.index("/// Call serially from the C callback")
        ]

        self.assertNotIn("String(describing:", dispatcher)
        self.assertIn('NSLog("Shaar engine event rejected")', dispatcher)


if __name__ == "__main__":
    unittest.main()
