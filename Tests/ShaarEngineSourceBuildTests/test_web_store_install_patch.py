# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Guard the real Web Store origin and its CRX install path in the Shaar stack."""

from pathlib import Path
import hashlib
import json
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0155-shaar-web-store-install.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"


class WebStoreInstallPatchTests(unittest.TestCase):
    def test_real_store_receives_privileged_apis_and_keeps_process_isolation(self):
        patch = PATCH.read_text()
        self.assertEqual(patch.count('+    "matches": ["https://chromewebstore.google.com/*"]'), 2)
        self.assertIn('+const char kNewChromeWebstoreBaseURL[] = "https://chromewebstore.google.com/";', patch)
        self.assertIn('+  list.push_back(url::Origin::Create(extension_urls::GetNewWebstoreLaunchURL()));', patch)
        self.assertNotIn('user_agent_utils', patch)

    def test_store_install_can_download_and_register_a_crx(self):
        patch = PATCH.read_text()
        self.assertIn('+    "https://clients2.google.com/service/update2/crx";', patch)
        self.assertIn('+  download_url_ = GetWebstoreInstallURL(extension_id, source);', patch)
        self.assertIn('+  crx_installer_->set_expected_id(approval->extension_id);', patch)
        self.assertIn('+  crx_installer_->InstallCrx(download.GetFullPath());', patch)

    def test_store_install_routes_consent_to_shaar_only_on_the_store_origin(self):
        patch = PATCH.read_text()
        self.assertIn('ExtensionInstallPrompt::GetDefaultShowDialogCallback()', patch)
        self.assertIn('HasSwitch("shaar-embedder")', patch)
        self.assertIn('ShaarShowInstallPrompt', patch)
        self.assertIn('url::Origin::Create(contents->GetLastCommittedURL())', patch)
        self.assertIn('GURL("https://chromewebstore.google.com/")', patch)
        self.assertIn('ShowExtensionInstallDialogImpl(', patch)
        self.assertNotIn('DeveloperPrivateLoadUnpackedFunction', patch)

    def test_patch_is_pinned_once_with_its_digest(self):
        entries = json.loads(MANIFEST.read_text())["patches"]
        matching = [entry for entry in entries if entry["file"] == str(PATCH.relative_to(ROOT))]
        self.assertEqual(len(matching), 1)
        self.assertEqual(matching[0]["sha256"], hashlib.sha256(PATCH.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
