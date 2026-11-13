# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep the File > Print route on the native print panel in Shaar."""

import hashlib
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0121-shaar-print-menu-native-panel.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"


class PrintMenuNativePanelPatchTests(unittest.TestCase):
    def test_menu_print_routes_to_basic_print_and_has_a_regression_test(self):
        patch = PATCH.read_text()
        self.assertIn("PrintPreviewNow", patch)
        self.assertIn('HasSwitch("shaar-embedder")', patch)
        self.assertIn("if (has_selection)", patch)
        self.assertIn("PrintNowImpl(rfh, /*print_selection_only=*/true)", patch)
        self.assertIn("return BasicPrint(rfh);", patch)
        self.assertIn("ShaarEmbedderMenuPrintUsesNativePath", patch)
        self.assertIn("ShaarEmbedderMenuPrintSelectionUsesNativePath", patch)
        self.assertIn("EXPECT_TRUE(observer.print_requested);", patch)

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
