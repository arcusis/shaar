# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ChromiumBackendEventContractTests(unittest.TestCase):
    def test_event_is_validated_before_borrowed_fields_are_read(self):
        source = (ROOT / "Sources/ChromiumBridge/ChromiumShaarBackend.mm").read_text()
        self.assertIn("BOOL ShaarEventHasValidSlices(", source)
        helper = source.split("BOOL ShaarEventHasValidSlices(", 1)[1].split("\n}", 1)[0]
        self.assertIn("event->size < sizeof(*event)", helper)
        for field in ("profile_id", "session_id", "window_id", "tab_id", "payload_json"):
            with self.subTest(field=field):
                self.assertIn(f"event->{field}", helper)
        self.assertIn("slice.size && !slice.data", helper)

        receiver = source.split("- (void)receiveEvent:(const shaar_event *)event {", 1)[1]
        validation = receiver.index("if (!ShaarEventHasValidSlices(event)) return;")
        payload_copy = receiver.index("dataWithBytes:event->payload_json.data")
        self.assertLess(validation, payload_copy)


if __name__ == "__main__":
    unittest.main()
