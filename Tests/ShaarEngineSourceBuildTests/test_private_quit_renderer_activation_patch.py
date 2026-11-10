# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep the 157 quit-cancel hook out of the Chromium 155 patch list."""

from pathlib import Path
import json
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0061-shaar-private-quit-renderer-activation.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"
LEGACY = ROOT / "ThirdParty/ChromiumEngine/patches/0044-shaar-quit-cancellation-callback.patch"


class PrivateQuitRendererActivationPatchTests(unittest.TestCase):
    def test_157_hook_is_not_in_the_155_patch_list(self):
        files = [entry["file"] for entry in json.loads(MANIFEST.read_text())["patches"]]
        self.assertNotIn(str(PATCH.relative_to(ROOT)), files)
        self.assertIn(str(LEGACY.relative_to(ROOT)), files)

    def test_157_hook_uses_the_renamed_unload_reset(self):
        source = PATCH.read_text()
        self.assertIn("EngineQuitCancelled", source)
        self.assertIn("ResetBeforeUnloadForShutdown", source)
        self.assertNotIn("ResetTryToCloseWindow", source)
        self.assertIn("ResetTryToCloseWindow", LEGACY.read_text())


if __name__ == "__main__":
    unittest.main()
