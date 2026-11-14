# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Pin developer-only Profiler.enable as command 81."""

from pathlib import Path
import hashlib
import json
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0046-shaar-devtools-profiler-enable.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"


class ProfilerEnablePatchTests(unittest.TestCase):
    def test_profiler_enable_is_developer_only_and_command_81(self):
        source = PATCH.read_text()
        self.assertIn("Profiler.enable", source)
        self.assertIn('"Profiler.enable", false, true', source)
        self.assertIn("SHAAR_DEVTOOLS_PROFILER_ENABLE = 81", source)
        self.assertIn("id <= SHAAR_DEVTOOLS_PROFILER_ENABLE", source)
        self.assertIn('"command":82', source)
        self.assertIn("unknown DevTools capability or command", source)
        self.assertIn("ProfilerEnableIsDeveloperOnlyAndCommand81", source)

    def test_patch_is_pinned_in_source_build(self):
        patches = json.loads(MANIFEST.read_text())["patches"]
        matching = [entry for entry in patches if entry["file"] == str(PATCH.relative_to(ROOT))]
        self.assertEqual(len(matching), 1)
        self.assertEqual(matching[0]["sha256"], hashlib.sha256(PATCH.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
