# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep the extension install hook on its assigned Chromium 157 patch number."""

from pathlib import Path
import hashlib
import json
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0135-shaar-extension-install.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"
LAYER = ROOT / "ThirdParty/ChromiumEngine/layer"
INSTALL_FILES = (
    "chrome/browser/shaar/BUILD.gn",
    "chrome/browser/shaar/extensions/shaar_extension_install.cc",
    "chrome/browser/shaar/extensions/shaar_extension_install.h",
    "chrome/browser/shaar/extensions/shaar_extensions.cc",
    "chrome/browser/shaar/extensions/shaar_extensions_unittest.cc",
)


class ExtensionInstallPatchTests(unittest.TestCase):
    def test_patch_hooks_the_embedder_dialog_only(self):
        source = PATCH.read_text()
        self.assertIn('HasSwitch("shaar-embedder")', source)
        self.assertIn("ShaarShowInstallPrompt", source)
        self.assertIn("weak_import", source)
        self.assertNotIn("document.title", source)

    def test_patch_blocks_extensions_page_unpacked_install_bypass(self):
        source = PATCH.read_text()
        self.assertIn('HasSwitch("shaar-embedder")', source)
        self.assertIn("DeveloperPrivateLoadUnpackedFunction", source)
        self.assertIn("managed through Shaar Settings", source)

    def test_layer_uses_chromium_permission_messages_and_manifest_binding(self):
        source = (LAYER / INSTALL_FILES[1]).read_text()
        self.assertIn("InstallPromptData", source)
        self.assertIn("GetInstallPromptPermissionSetForExtension", source)
        self.assertIn("SHA256HashString", source)
        self.assertIn("pending.manifest_sha256", source)
        self.assertIn("permissionsComplete", source)

    def test_patch_is_not_on_the_chromium_155_list(self):
        patches = json.loads(MANIFEST.read_text())["patches"]
        names = [entry["file"] for entry in patches]
        self.assertNotIn(str(PATCH.relative_to(ROOT)), names)
        self.assertNotIn(str(PATCH.relative_to(ROOT)), names)

    def test_install_layer_hashes_match_the_files(self):
        manifest = json.loads(MANIFEST.read_text())
        files = manifest["layer"]["files"]
        listed = manifest["moduleBlocks"]["extensions"]["layerFiles"]
        for relative in INSTALL_FILES:
            digest = hashlib.sha256((LAYER / relative).read_bytes()).hexdigest()
            self.assertEqual(files[relative], digest)
            self.assertIn(relative, listed)


if __name__ == "__main__":
    unittest.main()
