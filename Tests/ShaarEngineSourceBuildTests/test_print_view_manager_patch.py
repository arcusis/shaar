# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep Shaar scripted printing on Chromium's native print path."""

import hashlib
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0120-shaar-print-view-manager.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"


class PrintViewManagerPatchTests(unittest.TestCase):
    def test_scripted_print_routes_to_basic_print_and_covers_the_regression(self):
        patch = PATCH.read_text()
        self.assertIn('HasSwitch("shaar-embedder")', patch)
        self.assertIn("ShowScriptedPrintPreview", patch)
        self.assertIn("PrintForSystemDialogNow(base::DoNothing())", patch)
        self.assertIn("ShaarEmbedderScriptedPrintUsesNativePanel", patch)
        self.assertIn("EXPECT_TRUE(print_view_manager->system_dialog_shown);", patch)
        self.assertIn("if (!weak_this)", patch)
        self.assertIn("on_print_dialog_shown_callback_.Reset();", patch)
        self.assertIn("is_switching_to_system_dialog_ = false;", patch)
        self.assertIn("OnPrintPreviewRequestRejected(rfh_id);", patch)

    def test_patch_is_pinned_once_in_application_order(self):
        entries = json.loads(MANIFEST.read_text())["patches"]
        name = str(PATCH.relative_to(ROOT))
        matching = [entry for entry in entries if entry["file"] == name]
        self.assertEqual(len(matching), 1)
        self.assertEqual(matching[0]["sha256"], hashlib.sha256(PATCH.read_bytes()).hexdigest())
        prior = "ThirdParty/ChromiumEngine/patches/0078-shaar-trusted-click-layout.patch"
        self.assertLess(
            next(i for i, entry in enumerate(entries) if entry["file"] == prior),
            next(i for i, entry in enumerate(entries) if entry["file"] == name),
        )


if __name__ == "__main__":
    unittest.main()
