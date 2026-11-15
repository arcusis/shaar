"""Build tools must come from the pinned Chromium checkout."""

import hashlib
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0150-shaar-pinned-build-tools.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"


class PinnedBuildToolsPatchTests(unittest.TestCase):
    def test_devtools_uses_pinned_esbuild_for_gn_and_node_actions(self):
        patch = PATCH.read_text()
        entry = next(item for item in json.loads(MANIFEST.read_text())["patches"]
                     if item["file"] == str(PATCH.relative_to(ROOT)))
        self.assertEqual(hashlib.sha256(PATCH.read_bytes()).hexdigest(), entry["sha256"])
        self.assertIn('third_party/esbuild/esbuild', patch)
        self.assertIn('diff --git a/third_party/devtools-frontend/src/scripts/build/esbuild.js', patch)
        self.assertIn('+    devtoolsRootPath(),', patch)
        self.assertIn('+    \'third_party\',', patch)
        self.assertIn('+    \'esbuild\',', patch)
        self.assertNotIn('+    \'homebrew\',', patch)


if __name__ == "__main__":
    unittest.main()
