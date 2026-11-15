import hashlib
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
LAYER = ROOT / "ThirdParty/ChromiumEngine/layer"
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0156-shaar-external-app-consent.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"


class ExternalAppConsentPatchTests(unittest.TestCase):
    def test_native_dialog_routes_to_single_use_shaar_consent(self):
        patch = PATCH.read_text()
        source = (LAYER / "chrome/browser/shaar/external_app/shaar_external_app.cc").read_text()
        bridge = (ROOT / "Sources/ChromiumBridge/ChromiumShaarBackend.mm").read_text()
        audit = (ROOT / "Sources/ChromiumBridgeVerification/ChromiumBridgeVerification.mm").read_text()
        self.assertIn("shaar::external_app::Request", patch)
        self.assertIn("FindSelectedRegularTab", source)
        self.assertIn("GetWeakDocumentPtr", source)
        self.assertIn("base::BindOnce(&Sweep, id)", source)
        self.assertIn("Dismiss(request_id);  // Consume before", source)
        self.assertIn("ProbeMode(request.engine)", source)
        self.assertIn("shaar_external_app_probe_launches_json", audit)
        self.assertIn("self.onExternalAppRequest(request)", bridge)
        self.assertIn("_shaarExternalAppReply(requestID.UTF8String, accepted ? 1 : 0)", bridge)

    def test_manifest_lists_exact_patch_and_layer_digests(self):
        manifest = json.loads(MANIFEST.read_text())
        listed = {entry["file"]: entry["sha256"] for entry in manifest["patches"]}
        name = str(PATCH.relative_to(ROOT))
        self.assertEqual(listed[name], hashlib.sha256(PATCH.read_bytes()).hexdigest())
        self.assertEqual(len(manifest["patches"]), 88)
        layer = manifest["layer"]
        self.assertEqual(
            set(layer["files"]),
            {str(path.relative_to(LAYER)) for path in LAYER.rglob("*") if path.is_file()},
        )
        digest = hashlib.sha256()
        for name, expected in sorted(layer["files"].items()):
            self.assertEqual(hashlib.sha256((LAYER / name).read_bytes()).hexdigest(), expected)
            digest.update(name.encode() + b"\0" + expected.encode() + b"\n")
        self.assertEqual(layer["sha256"], digest.hexdigest())


if __name__ == "__main__":
    unittest.main()
