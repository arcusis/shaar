# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Pin the iCloud Keychain window fallback and the engine team id."""

from pathlib import Path
import hashlib
import json
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0061-shaar-icloud-passkey-window.patch"
BRANDING = ROOT / "ThirdParty/ChromiumEngine/patches/0007-shaar-branding.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"


def pinned(path: Path):
    manifest = json.loads(MANIFEST.read_text())
    relative = str(path.relative_to(ROOT))
    matching = [entry for entry in manifest["patches"] if entry["file"] == relative]
    return matching, hashlib.sha256(path.read_bytes()).hexdigest()


class PasskeyWindowPatchTests(unittest.TestCase):
    def test_hosting_window_is_used_when_the_page_has_no_widget(self):
        source = PATCH.read_text()
        self.assertIn("web_contents->GetTopLevelNativeWindow()", source)
        self.assertIn("discovery_factory->set_nswindow(hosting)", source)
        self.assertIn("Shaar reparents the page", source)
        self.assertIn("return;", source)
        self.assertNotIn("IsICloudDriveEnabled", source)
        self.assertNotIn("credentials.get", source)

    def test_patches_are_pinned_in_source_build(self):
        matching, digest = pinned(PATCH)
        self.assertEqual(len(matching), 1)
        self.assertEqual(matching[0]["sha256"], digest)
        branding, branding_digest = pinned(BRANDING)
        self.assertEqual(len(branding), 1)
        self.assertEqual(branding[0]["sha256"], branding_digest)
        self.assertIn("-MAC_TEAM_ID=\n+MAC_TEAM_ID=F9Z784RA6D\n", BRANDING.read_text())


if __name__ == "__main__":
    unittest.main()
