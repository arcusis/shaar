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
        self.assertIn("chrome/browser/ui/tab_helpers.cc", source)
        guard = r"AreExtensionsDisabledForProfile\(profile\)\) \{"
        self.assertEqual(len(re.findall(guard, source)), 2)
        for helper in (
            "AppTabHelper",
            "NavigationExtensionEnabler",
            "WebNavigationTabObserver",
            "TabHelper",
        ):
            self.assertRegex(source, rf"\+\s+extensions::{helper}::CreateForWebContents")

    def test_patch_is_pinned_in_source_build(self):
        patches = json.loads(MANIFEST.read_text())["patches"]
        matching = [entry for entry in patches if entry["file"] == str(PATCH.relative_to(ROOT))]
        self.assertEqual(len(matching), 1)
        self.assertEqual(matching[0]["sha256"], hashlib.sha256(PATCH.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
