"""Keep the Web Store fixture gate consistent with the copied Shaar layer."""

import hashlib
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0076-shaar-web-store-fit-test-host.patch"
LAYER = ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/extensions"


class WebStoreFitPatchTests(unittest.TestCase):
    def test_fixture_gate_uses_layer_declaration_and_regression_test(self):
        manifest = json.loads((ROOT / "ThirdParty/ChromiumEngine/source-build.json").read_text())
        entry = next(item for item in manifest["patches"] if item["file"] == str(PATCH.relative_to(ROOT)))
        patch = PATCH.read_bytes()
        self.assertEqual(hashlib.sha256(patch).hexdigest(), entry["sha256"])
        self.assertIn(b"bool WebStoreFitURLAllowed(const GURL& url, bool testing)", patch)
        self.assertIn(b'url.host() == "127.0.0.1"', patch)
        self.assertIn(b'url.path() == "/web-store-fit"', patch)
        self.assertIn("bool WebStoreFitURLAllowed(const GURL& url, bool testing);", (LAYER / "shaar_extensions.h").read_text())
        self.assertIn("WebStoreFitAllowsLoopbackOnlyInTesting", (LAYER / "shaar_extensions_unittest.cc").read_text())
        self.assertNotIn(b"--- a/chrome/browser/shaar/extensions/shaar_extensions_unittest.cc", patch)


if __name__ == "__main__":
    unittest.main()
