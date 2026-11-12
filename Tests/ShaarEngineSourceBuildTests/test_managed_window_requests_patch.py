# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep Chromium 157 page and extension windows inside the Shaar embedder."""

from pathlib import Path
import hashlib
import json
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0083-shaar-managed-window-requests.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"
LAYER = ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar"


class ManagedWindowRequestPatchTests(unittest.TestCase):
    def test_patch_routes_both_chromium_window_entry_points(self):
        source = PATCH.read_text()
        self.assertIn("AdoptPageWebContents", source)
        self.assertIn("user_gesture", source)
        self.assertIn("engine_requested", source)
        self.assertIn("SetEngineRequestedWindowHandler", source)

    def test_layer_requires_gesture_and_rejects_local_file_navigation(self):
        lifecycle = (LAYER / "windows_tabs/shaar_windows_tabs_lifecycle.cc").read_text()
        event_bridge = (LAYER / "engine/shaar_event_bridge.cc").read_text()
        navigation = (LAYER / "navigation/shaar_navigation.cc").read_text()
        navigation_test = (LAYER / "navigation/shaar_navigation_unittest.cc").read_text()
        abi = (LAYER / "public/shaar_engine.h").read_text()
        exports = (LAYER / "shaar_engine.exports").read_text()
        self.assertIn("RequestAppWindow", lifecycle)
        self.assertIn("AdoptPageWebContents", lifecycle)
        self.assertIn("CreateEngineRequestedBrowser", lifecycle)
        self.assertIn("!user_gesture", event_bridge)
        self.assertIn("shaar_window_request_fn on_window_request", abi)
        self.assertIn("SHAAR_ENGINE_ABI_MINOR 13u", abi)
        self.assertIn("_shaar_tab_find", exports)
        self.assertIn("shaar_tab_find(", lifecycle)
        self.assertNotIn('scheme == "file"', navigation)
        self.assertIn('ValidateURL("file:///etc/passwd", &canonical)', navigation_test)

    def test_patch_digest_is_pinned_once(self):
        manifest = json.loads(MANIFEST.read_text())
        relative = str(PATCH.relative_to(ROOT))
        entries = [entry for entry in manifest["patches"] if entry["file"] == relative]
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["sha256"], hashlib.sha256(PATCH.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
