"""Keep DevTools Network clients attached long enough to emit navigation requests."""

from pathlib import Path
import hashlib
import json
import unittest


ROOT = Path(__file__).resolve().parents[2]
PANEL = ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/devtools/shaar_devtools_panel.cc"
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0147-shaar-devtools-network-navigation.patch"


class DevToolsNetworkNavigationEventTests(unittest.TestCase):
    def test_committed_navigation_does_not_discard_queued_document_requests(self):
        source = PANEL.read_text()
        self.assertNotIn("DidFinishNavigation", source)
        self.assertIn("void WebContentsDestroyed() override { Close(); }", source)
        flush = source.split("  void Flush() {", 1)[1].split("  shaar_engine* engine_;", 1)[0]
        self.assertIn("if (!StillOwnsTarget())", flush)
        self.assertIn("Emit(payload);", flush)
        patch = PATCH.read_text()
        self.assertIn("-  void DidFinishNavigation(", patch)
        self.assertNotIn("+  void DidFinishNavigation(", patch)
        self.assertIn("WebContentsDestroyed() override { Close(); }", patch)

    def test_patch_and_layer_hashes_match_source_build_manifest(self):
        manifest = json.loads((ROOT / "ThirdParty/ChromiumEngine/source-build.json").read_text())
        patch_name = str(PATCH.relative_to(ROOT))
        listed = {entry["file"]: entry["sha256"] for entry in manifest["patches"]}
        self.assertEqual(hashlib.sha256(PATCH.read_bytes()).hexdigest(), listed[patch_name])
        layer = manifest["layer"]
        for name, expected in layer["files"].items():
            path = ROOT / "ThirdParty/ChromiumEngine/layer" / name
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), expected, name)
        digest = hashlib.sha256()
        for name, expected in sorted(layer["files"].items()):
            digest.update(name.encode("utf-8") + b"\0" + expected.encode("ascii") + b"\n")
        self.assertEqual(digest.hexdigest(), layer["sha256"])


if __name__ == "__main__":
    unittest.main()
