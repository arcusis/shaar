# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Pin the checkout fixes a clean layer overlay still needs before it compiles."""

from pathlib import Path
import hashlib
import json
import unittest


ROOT = Path(__file__).resolve().parents[2]
LAYER = ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar"
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0048-shaar-layer-compile-fixes.patch"
COOKIES = ROOT / "ThirdParty/ChromiumEngine/patches/0019-shaar-site-cookie-items.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"


class LayerCompileFixesPatchTests(unittest.TestCase):
    def test_profile_origin_and_request_counter_compile(self):
        source = PATCH.read_text()
        self.assertIn("tab.browser->GetProfile()->IsOffTheRecord()", source)
        self.assertIn("request.security_origin.DeprecatedGetOriginAsURL()", source)
        self.assertIn("static uint64_t next = 0;", source)
        self.assertIn("-  static base::NoDestructor<uint64_t> next(0);", source)
        self.assertIn("-        tab.browser->profile()->IsOffTheRecord())", source)
        self.assertIn("-  const GURL origin = request.security_origin.GetOrigin();", source)

    def test_cookie_opcodes_stay_in_the_site_data_patch(self):
        source = COOKIES.read_text()
        self.assertIn("SHAAR_OP_SITE_COOKIE_ITEMS = 709", source)
        self.assertIn("SHAAR_OP_SITE_COOKIE_SET = 710", source)
        self.assertIn("SHAAR_OP_SITE_COOKIE_DELETE = 711", source)

    def test_compile_fixes_are_in_the_pinned_layer(self):
        patches = json.loads(MANIFEST.read_text())["patches"]
        files = [entry["file"] for entry in patches]
        compile_fixes = str(PATCH.relative_to(ROOT))
        capture = "ThirdParty/ChromiumEngine/patches/0050-shaar-media-capture-events.patch"
        self.assertNotIn(compile_fixes, files)
        self.assertNotIn(capture, files)
        self.assertIn("tab.browser->GetProfile()->IsOffTheRecord()",
                      (LAYER / "windows_tabs/shaar_windows_tabs.cc").read_text())
        self.assertIn("static uint64_t next = 0;",
                      (LAYER / "media/shaar_media_permission.cc").read_text())
        restored = (
            "+        tab.browser->profile()->IsOffTheRecord()",
            "+  static base::NoDestructor<uint64_t> next(0);",
            "+  const GURL origin = request.security_origin.GetOrigin();",
        )
        for entry in patches:
            text = (ROOT / entry["file"]).read_text()
            for line in restored:
                self.assertNotIn(line, text, entry["file"])


if __name__ == "__main__":
    unittest.main()
