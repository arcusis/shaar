# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep private tabs from attaching helpers that require extension observers."""

from pathlib import Path
import hashlib
import json
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0005-private-extension-tab-helpers.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"


class PrivateExtensionTabHelpersTests(unittest.TestCase):
    def test_disabled_profile_skips_extension_tab_helpers(self):
        source = PATCH.read_text()
        self.assertIn("chrome/browser/ui/tabs/tab_features.cc", source)
        guard = r"AreExtensionsDisabledForProfile\(profile\)\) \{"
        self.assertEqual(len(re.findall(guard, source)), 4)
        for helper in (
            "WebNavigationTabObserver",
            "TabHelper",
        ):
            self.assertRegex(source, rf"\+\s+extensions::{helper}::CreateForWebContents")
        for helper in ("AppTabHelper", "NavigationExtensionEnabler"):
            self.assertRegex(source, rf"\+\s+std::make_unique<extensions::{helper}>")
        self.assertIn("+  navigation_extension_enabler_.reset();", source)

    def test_patch_is_pinned_in_source_build(self):
        patches = json.loads(MANIFEST.read_text())["patches"]
        matching = [entry for entry in patches if entry["file"] == str(PATCH.relative_to(ROOT))]
        self.assertEqual(len(matching), 1)
        self.assertEqual(matching[0]["sha256"], hashlib.sha256(PATCH.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
