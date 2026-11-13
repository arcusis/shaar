# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Pin the Chromium chooser handoff used by the native device chooser."""

from pathlib import Path
import hashlib
import json
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0125-shaar-device-chooser.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"


class DeviceChooserPatchTests(unittest.TestCase):
    def test_usb_controller_is_hooked_into_shaar_chooser(self):
        source = PATCH.read_text()
        self.assertIn("UsbChooserController::UsbChooserController", source)
        self.assertIn('SetShaarTransport("usb")', source)
        self.assertIn('HasSwitch("shaar-embedder")', source)
        self.assertIn(
            "return shaar::chooser::ShowDeviceChooser(owner, std::move(controller));", source)
        self.assertIn("ShaarDeviceChooser", source)
        self.assertIn('"deviceChooserRequested"', source)
        self.assertIn('"deviceChooserUpdated"', source)
        self.assertIn('"deviceChooserDismissed"', source)
        self.assertIn("shaar_device_chooser_register", source)
        self.assertIn("base::UnguessableToken::Create().ToString()", source)
        self.assertNotIn("NextID()", source)
        self.assertIn('option.Set("optionId", option_id)', source)
        self.assertIn("shown_options_.clear()", source)
        self.assertIn("shown_options_.find(option_id)", source)
        self.assertNotIn('option.Set("index"', source)
        self.assertIn("public content::WebContentsObserver", source)
        self.assertIn("void WebContentsDestroyed() override", source)
        self.assertIn("void DidFinishNavigation(content::NavigationHandle* navigation)", source)
        self.assertIn(
            "shown->second >= std::min(controller_->NumOptions(), kMaximumOptions)", source)
        self.assertNotIn("optionID", source)

    def test_patch_digest_is_pinned_in_source_build(self):
        manifest = json.loads(MANIFEST.read_text())
        relative = str(PATCH.relative_to(ROOT))
        matching = [entry for entry in manifest["patches"] if entry["file"] == relative]
        digest = hashlib.sha256(PATCH.read_bytes()).hexdigest()
        self.assertEqual(len(matching), 1)
        self.assertEqual(matching[0]["sha256"], digest)


if __name__ == "__main__":
    unittest.main()
