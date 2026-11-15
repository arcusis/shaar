"""The Chromium 157 window registry fix is part of the release patch series."""

import hashlib
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0151-shaar-headless-cgwindow-registry-quit.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"


class HeadlessCGWindowRegistryPatchTests(unittest.TestCase):
    def test_patch_follows_build_tool_patch_and_has_matching_digest(self):
        entries = json.loads(MANIFEST.read_text())["patches"]
        paths = [entry["file"] for entry in entries]
        position = paths.index(str(PATCH.relative_to(ROOT)))
        self.assertEqual(
            "ThirdParty/ChromiumEngine/patches/0150-shaar-pinned-build-tools.patch",
            paths[position - 1],
        )
        self.assertEqual(hashlib.sha256(PATCH.read_bytes()).hexdigest(), entries[position]["sha256"])

    def test_zero_and_reused_ids_have_regression_coverage(self):
        patch = PATCH.read_text()
        self.assertIn("+  if (cg_window_id_ != 0)", patch)
        self.assertIn("+  if (found != GetMap().end() && found->second == this)", patch)
        self.assertIn("+  if (cg_window_id == 0)", patch)
        self.assertIn("+    if (!host->compositor_ || cg_window_id == 0) {", patch)
        self.assertIn("+TEST(ScopedCGWindowIDTest, HeadlessWindowsDoNotEnterRegistry)", patch)
        self.assertIn("+TEST(ScopedCGWindowIDTest, ReplacedOwnerCannotEraseNewOwner)", patch)
        self.assertIn("+TEST(ScopedCGWindowIDTest, MissingOwnerCanBeDestroyed)", patch)
        self.assertIn('+    "//components/viz/common",', patch)


if __name__ == "__main__":
    unittest.main()
