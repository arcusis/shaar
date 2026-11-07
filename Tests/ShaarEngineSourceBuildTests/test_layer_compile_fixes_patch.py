# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Pin the checkout fixes a clean layer overlay still needs before it compiles."""

from pathlib import Path
import hashlib
import json
import unittest


ROOT = Path(__file__).resolve().parents[2]
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

    def test_patch_is_pinned_last(self):
        patches = json.loads(MANIFEST.read_text())["patches"]
        files = [entry["file"] for entry in patches]
        self.assertEqual(files[-1], str(PATCH.relative_to(ROOT)))
        self.assertLess(
            files.index("ThirdParty/ChromiumEngine/patches/0019-shaar-site-cookie-items.patch"),
            files.index(str(PATCH.relative_to(ROOT))),
        )
        matching = [entry for entry in patches if entry["file"] == str(PATCH.relative_to(ROOT))]
        self.assertEqual(matching[0]["sha256"], hashlib.sha256(PATCH.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
