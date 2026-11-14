# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from pathlib import Path
import hashlib
import json
import unittest


ROOT = Path(__file__).resolve().parents[2]
LAYER = ROOT / "ThirdParty/ChromiumEngine/layer"
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0146-shaar-hidden-trusted-scroll.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"


class HiddenTrustedScrollPatchTests(unittest.TestCase):
    def test_scroll_uses_allowlisted_native_wheel_input(self):
        source = (LAYER / "chrome/browser/shaar/devtools/shaar_devtools.cc").read_text()
        test = (LAYER / "chrome/browser/shaar/devtools/shaar_devtools_unittest.cc").read_text()
        self.assertIn("DispatchTrustedScroll", source)
        self.assertIn("ForwardWheelEvent(event)", source)
        self.assertIn("ParseProbeScrollArguments", source)
        self.assertIn("SHAAR_OP_PROBE_TRUSTED_SCROLL", test)
        self.assertIn('"feed"', test)

    def test_source_patch_and_layer_hashes_match_manifest(self):
        manifest = json.loads(MANIFEST.read_text())
        listed = {entry["file"]: entry["sha256"] for entry in manifest["patches"]}
        name = str(PATCH.relative_to(ROOT))
        self.assertNotIn(name, listed)
        for path, expected in manifest["layer"]["files"].items():
            content = LAYER / path
            self.assertTrue(content.is_file(), path)
            self.assertEqual(hashlib.sha256(content.read_bytes()).hexdigest(), expected, path)
        digest = hashlib.sha256()
        for path, expected in sorted(manifest["layer"]["files"].items()):
            digest.update(path.encode("utf-8") + b"\0" + expected.encode("ascii") + b"\n")
        self.assertEqual(digest.hexdigest(), manifest["layer"]["sha256"])

    def test_layer_contains_wheel_dispatch_and_regression_case(self):
        source = (LAYER / "chrome/browser/shaar/devtools/shaar_devtools.cc").read_text()
        tests = (LAYER / "chrome/browser/shaar/devtools/shaar_devtools_unittest.cc").read_text()
        self.assertIn("ForwardWheelEvent", source)
        self.assertIn("ParseProbeScrollArguments", source)
        self.assertIn("SHAAR_OP_PROBE_TRUSTED_SCROLL", tests)


if __name__ == "__main__":
    unittest.main()
