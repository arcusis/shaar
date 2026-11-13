# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import json
import re
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]


class DependencyPinTests(unittest.TestCase):
    def test_sparkle_manifest_and_lockfile_pin_the_same_exact_release(self):
        manifest = (REPO / "Package.swift").read_text()
        resolved = json.loads((REPO / "Package.resolved").read_text())
        match = re.search(
            r'\.package\(url: "https://github\.com/sparkle-project/Sparkle", exact: "([^"]+)"\)',
            manifest,
        )

        self.assertIsNotNone(match, "Sparkle must use an exact version requirement")
        pins = [pin for pin in resolved["pins"] if pin["identity"] == "sparkle"]
        self.assertEqual(len(pins), 1)
        self.assertEqual(pins[0]["location"], "https://github.com/sparkle-project/Sparkle")
        self.assertEqual(pins[0]["state"]["version"], match.group(1))
        self.assertRegex(pins[0]["state"]["revision"], r"^[0-9a-f]{40}$")

    def test_engine_release_uses_a_versioned_tag_and_sha256_pin(self):
        pin = json.loads((REPO / "ThirdParty/ChromiumEngine/pin.json").read_text())
        fetch = (REPO / "scripts/fetch-engine.sh").read_text()

        self.assertEqual(pin["schemaVersion"], 1)
        self.assertEqual(pin["sourceKind"], "shaar")
        self.assertRegex(
            pin["releaseTag"], r"^engine-157\.0\.8103\.51-shaar\.[1-9][0-9]*$"
        )
        self.assertRegex(pin["sha256"], r"^[0-9a-f]{64}$")
        self.assertIn('jq -er .sha256 "$pin"', fetch)
        self.assertIn("shasum -a 256", fetch)


if __name__ == "__main__":
    unittest.main()
