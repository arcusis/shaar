# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep Shaar's OTR preference overlay ephemeral in the pinned engine."""

import hashlib
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0153-shaar-private-otr-pref-isolation.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"


class PrivateOTRPreferenceIsolationPatchTests(unittest.TestCase):
    def test_patch_is_last_and_has_matching_digest(self):
        entries = json.loads(MANIFEST.read_text())["patches"]
        self.assertEqual(str(PATCH.relative_to(ROOT)), entries[-1]["file"])
        self.assertEqual(hashlib.sha256(PATCH.read_bytes()).hexdigest(), entries[-1]["sha256"])

    def test_all_off_the_record_profiles_use_the_non_syncing_pref_service(self):
        patch = PATCH.read_text()
        self.assertIn("prefs_ = CreateAutomationPrefService(", patch)
        self.assertIn("must not sync preference changes to the original", patch)
        self.assertIn("-    prefs_ = CreateIncognitoPrefServiceSyncable(", patch)


if __name__ == "__main__":
    unittest.main()
