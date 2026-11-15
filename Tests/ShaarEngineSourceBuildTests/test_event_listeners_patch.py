# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Pin inspector-only event listener inspection and bounded call arguments."""

from pathlib import Path
import hashlib
import json
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0043-shaar-devtools-event-listeners.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"


class EventListenersPatchTests(unittest.TestCase):
    def test_listeners_are_inspector_only_and_arguments_are_bounded(self):
        source = PATCH.read_text()
        self.assertIn("DOMDebugger.getEventListeners", source)
        self.assertIn('"DOMDebugger.getEventListeners", true, false', source)
        self.assertIn("SHAAR_DEVTOOLS_DOM_DEBUGGER_GET_EVENT_LISTENERS = 80", source)
        self.assertIn("id <= SHAAR_DEVTOOLS_DOM_DEBUGGER_GET_EVENT_LISTENERS", source)
        self.assertIn("CallArgumentsAreValid", source)
        self.assertIn('"command":81', source)
        self.assertIn("unknown DevTools capability or command", source)

    def test_patch_is_pinned_in_source_build(self):
        patches = json.loads(MANIFEST.read_text())["patches"]
        matching = [entry for entry in patches if entry["file"] == str(PATCH.relative_to(ROOT))]
        self.assertEqual(len(matching), 1)
        self.assertEqual(matching[0]["sha256"], hashlib.sha256(PATCH.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
