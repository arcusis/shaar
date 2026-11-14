# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from pathlib import Path
import hashlib
import json
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0122-shaar-print-selection-option.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"


class PrintSelectionOptionPatchTests(unittest.TestCase):
    def test_native_panel_selection_option_is_conditional(self):
        source = PATCH.read_text()
        self.assertIn("NSPrintPanelShowsCopies", source)
        self.assertIn("NSPrintPanelShowsPageRange", source)
        self.assertIn("if (has_selection)", source)
        self.assertIn("panel.options |= NSPrintPanelShowsPrintSelection;", source)

    def test_selection_option_is_cleared_when_page_has_no_selection(self):
        source = PATCH.read_text()
        self.assertIn("} else {", source)
        self.assertIn(
            "panel.options &= ~NSPrintPanelShowsPrintSelection;", source
        )

    def test_patch_is_pinned_after_embedder_print_routing(self):
        manifest = json.loads(MANIFEST.read_text())
        relative = str(PATCH.relative_to(ROOT))
        files = [entry["file"] for entry in manifest["patches"]]
        self.assertIn(relative, files)
        self.assertGreater(files.index(relative), files.index(
            "ThirdParty/ChromiumEngine/patches/0078-shaar-trusted-click-layout.patch"
        ))
        matching = [entry for entry in manifest["patches"] if entry["file"] == relative]
        self.assertEqual(len(matching), 1)
        self.assertEqual(
            matching[0]["sha256"], hashlib.sha256(PATCH.read_bytes()).hexdigest()
        )


if __name__ == "__main__":
    unittest.main()
