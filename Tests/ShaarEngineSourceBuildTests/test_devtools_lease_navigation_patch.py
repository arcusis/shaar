# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep the Chromium 157 navigation callback's complete type available."""

from pathlib import Path
import hashlib
import json
import unittest

ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0049-shaar-devtools-lease-navigation.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"


class DevToolsLeaseNavigationPatchTests(unittest.TestCase):
    def test_navigation_callback_has_complete_type(self):
        source = PATCH.read_text()
        self.assertIn('+#include "content/public/browser/navigation_handle.h"', source)
        self.assertIn("+  void DidFinishNavigation(content::NavigationHandle* navigation) override", source)
        self.assertIn("navigation->HasCommitted()", source)

    def test_patch_digest_matches_ordered_manifest(self):
        entries = json.loads(MANIFEST.read_text())["patches"]
        matching = [entry for entry in entries if entry["file"] == str(PATCH.relative_to(ROOT))]
        self.assertEqual(len(matching), 1)
        self.assertEqual(matching[0]["sha256"], hashlib.sha256(PATCH.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
