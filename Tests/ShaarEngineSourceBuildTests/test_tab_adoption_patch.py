# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Pin page-opened tab adoption as patch 0047."""

from pathlib import Path
import hashlib
import json
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0047-shaar-tab-adoption.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"


class TabAdoptionPatchTests(unittest.TestCase):
    def test_page_open_becomes_a_shaar_tab(self):
        source = PATCH.read_text()
        self.assertIn("SHAAR_ENGINE_ABI_MINOR 9u", source)
        self.assertIn("shaar_tab_find", source)
        self.assertIn("_shaar_tab_find", source)
        self.assertIn("AdoptPageWebContents", source)
        self.assertIn('payload.Set("kind", "opened")', source)
        self.assertIn("ToUpperASCII", source)
        self.assertIn("HasSwitch(\"shaar-embedder\")", source)

    def test_patch_is_pinned_in_source_build(self):
        manifest = json.loads(MANIFEST.read_text())
        patches = manifest["patches"]
        matching = [entry for entry in patches if entry["file"] == str(PATCH.relative_to(ROOT))]
        self.assertEqual(len(matching), 1)
        self.assertEqual(matching[0]["sha256"], hashlib.sha256(PATCH.read_bytes()).hexdigest())
        self.assertIn("_shaar_tab_find", manifest["requiredExports"])


if __name__ == "__main__":
    unittest.main()
