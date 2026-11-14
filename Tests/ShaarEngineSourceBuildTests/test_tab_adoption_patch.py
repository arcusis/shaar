# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Pin page-opened tab adoption as patch 0047."""

from pathlib import Path
import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0047-shaar-tab-adoption.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"
SPEC = importlib.util.spec_from_file_location(
    "test_tab_adoption_shipping", ROOT / "scripts/test-tab-adoption-shipping.py"
)
TAB_ADOPTION = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = TAB_ADOPTION
SPEC.loader.exec_module(TAB_ADOPTION)


class TabAdoptionPatchTests(unittest.TestCase):
    def test_receipt_writer_rejects_symlink_without_overwriting_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "outside.json"
            target.write_text("preserve this", encoding="utf-8")
            receipt = root / "receipt.json"
            receipt.symlink_to(target)

            with self.assertRaisesRegex(ValueError, "tab adoption receipt path must not be a symlink"):
                TAB_ADOPTION.write_receipt(receipt, {"passed": True})

            self.assertEqual(target.read_text(encoding="utf-8"), "preserve this")

    def test_page_open_becomes_a_shaar_tab(self):
        source = PATCH.read_text()
        self.assertIn("AdoptPageWebContents", source)
        self.assertIn("user_gesture", source)
        layer = ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar"
        self.assertIn("SHAAR_ENGINE_ABI_MINOR 17u", (layer / "public/shaar_engine.h").read_text())
        self.assertIn("shaar_tab_find", (layer / "windows_tabs/shaar_windows_tabs_lifecycle.cc").read_text())
        self.assertIn("_shaar_tab_find", (layer / "shaar_engine.exports").read_text())
        source = (layer / "windows_tabs/shaar_windows_tabs_lifecycle.cc").read_text()
        self.assertIn('payload.Set("kind", "opened")', source)
        self.assertIn("ToUpperASCII", source)

    def test_patch_is_pinned_in_source_build(self):
        manifest = json.loads(MANIFEST.read_text())
        patches = manifest["patches"]
        matching = [entry for entry in patches if entry["file"] == str(PATCH.relative_to(ROOT))]
        self.assertEqual(len(matching), 1)
        self.assertEqual(matching[0]["sha256"], hashlib.sha256(PATCH.read_bytes()).hexdigest())
        self.assertIn("_shaar_tab_find", manifest["requiredExports"])


if __name__ == "__main__":
    unittest.main()
