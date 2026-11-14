"""Keep the hidden-QA reload regression in the engine layer and source patch."""

from pathlib import Path
import hashlib
import json
import unittest


ROOT = Path(__file__).resolve().parents[2]
LAYER = ROOT / "ThirdParty/ChromiumEngine/layer"
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0145-shaar-reload-pending-navigation.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"


class PendingNavigationReloadTests(unittest.TestCase):
    def test_reload_restarts_pending_url_and_replaces_current_entry(self):
        source = (LAYER / "chrome/browser/shaar/navigation/shaar_navigation.cc").read_text()
        unit = (LAYER / "chrome/browser/shaar/navigation/shaar_navigation_unittest.cc").read_text()
        self.assertIn("controller->GetPendingEntry()", source)
        self.assertIn("params.reload_type = bypass_cache", source)
        self.assertIn("params.should_replace_current_entry = true", source)
        self.assertIn("ReloadDuringNavigationKeepsPendingDestination", unit)
        self.assertIn("https://example.test/slow", unit)

    def test_source_patch_and_layer_hashes_match_manifest(self):
        manifest = json.loads(MANIFEST.read_text())
        listed = {entry["file"]: entry["sha256"] for entry in manifest["patches"]}
        patch_name = str(PATCH.relative_to(ROOT))
        self.assertNotIn(patch_name, listed)
        for name, expected in manifest["layer"]["files"].items():
            path = LAYER / name
            self.assertTrue(path.is_file(), name)
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), expected, name)
        digest = hashlib.sha256()
        for name, expected in sorted(manifest["layer"]["files"].items()):
            digest.update(name.encode("utf-8") + b"\0" + expected.encode("ascii") + b"\n")
        self.assertEqual(digest.hexdigest(), manifest["layer"]["sha256"])

    def test_layer_carries_the_regression(self):
        self.assertIn("GetPendingEntry", (LAYER / "chrome/browser/shaar/navigation/shaar_navigation.cc").read_text())
        self.assertIn("ReloadDuringNavigationKeepsPendingDestination", (LAYER / "chrome/browser/shaar/navigation/shaar_navigation_unittest.cc").read_text())


if __name__ == "__main__":
    unittest.main()
