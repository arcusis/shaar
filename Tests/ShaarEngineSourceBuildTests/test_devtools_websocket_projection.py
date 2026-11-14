from pathlib import Path
import hashlib
import json
import unittest

ROOT = Path(__file__).resolve().parents[2]
LAYER = ROOT / "ThirdParty/ChromiumEngine/layer"
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0148-shaar-devtools-websocket-projection.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"


class DevToolsWebSocketProjectionTests(unittest.TestCase):
    def test_native_projection_covers_websocket_lifecycle_and_bounded_payload(self):
        panel = (LAYER / "chrome/browser/shaar/devtools/shaar_devtools_panel.cc").read_text()
        tests = (LAYER / "chrome/browser/shaar/devtools/shaar_devtools_unittest.cc").read_text()
        header = (LAYER / "chrome/browser/shaar/public/shaar_engine.h").read_text()
        for method in (
            "Network.webSocketCreated",
            "Network.webSocketHandshakeResponseReceived",
            "Network.webSocketFrameSent",
            "Network.webSocketFrameReceived",
            "Network.webSocketClosed",
        ):
            self.assertIn(method, panel)
        self.assertIn('PutString(&data, "payload", response->FindString("payloadData")', panel)
        self.assertIn("SHAAR_DEVTOOLS_PANEL_WEB_SOCKET_CREATED = 31", header)
        self.assertIn("ProjectsWebSocketLifecycleAndFrames", tests)
        self.assertIn('output.find("secret")', tests)

    def test_patch_and_layer_hashes_match_manifest(self):
        manifest = json.loads(MANIFEST.read_text())
        patches = {entry["file"]: entry["sha256"] for entry in manifest["patches"]}
        patch_name = str(PATCH.relative_to(ROOT))
        self.assertNotIn(patch_name, patches)
        for path, expected in manifest["layer"]["files"].items():
            self.assertEqual(hashlib.sha256((LAYER / path).read_bytes()).hexdigest(), expected, path)
        digest = hashlib.sha256()
        for path, expected in sorted(manifest["layer"]["files"].items()):
            digest.update(path.encode() + b"\0" + expected.encode("ascii") + b"\n")
        self.assertEqual(digest.hexdigest(), manifest["layer"]["sha256"])
        self.assertIn("webSocketFrameReceived", (LAYER / "chrome/browser/shaar/devtools/shaar_devtools_panel.cc").read_text())


if __name__ == "__main__":
    unittest.main()
