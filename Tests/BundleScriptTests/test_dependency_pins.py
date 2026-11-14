# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import json
import importlib.util
import re
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import Mock, patch


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("generate_dmg_layout", REPO / "scripts/generate-dmg-layout.py")
DMG_LAYOUT = importlib.util.module_from_spec(SPEC)
DS_STORE_STUB = types.ModuleType("ds_store")
DS_STORE_STUB.DSStore = type("DSStore", (), {"open": Mock()})
MAC_ALIAS_STUB = types.ModuleType("mac_alias")
for symbol in (
    "ALIAS_EJECTABLE_DISK", "ALIAS_HFS_VOLUME_SIGNATURE", "ALIAS_KIND_FILE", "ALIAS_NO_CNID",
    "Alias", "TargetInfo", "VolumeInfo",
):
    setattr(MAC_ALIAS_STUB, symbol, object())
with patch.dict(sys.modules, {"ds_store": DS_STORE_STUB, "mac_alias": MAC_ALIAS_STUB}):
    SPEC.loader.exec_module(DMG_LAYOUT)


class DependencyPinTests(unittest.TestCase):
    @staticmethod
    def assert_exact_package_pins(test_case, manifest, resolved):
        declarations = re.findall(r"\.package\((.*?)\)", manifest, re.DOTALL)
        external = []
        for declaration in declarations:
            if "url:" not in declaration:
                continue
            match = re.fullmatch(
                r'\s*url:\s*"([^"]+)"\s*,\s*exact:\s*"([^"]+)"\s*',
                declaration,
            )
            test_case.assertIsNotNone(
                match, f"external SwiftPM dependency must use an exact version: {declaration}"
            )
            external.append((match.group(1), match.group(2)))

        pins = resolved.get("pins")
        test_case.assertIsInstance(pins, list)
        for location, version in external:
            matching = [pin for pin in pins if pin.get("location") == location]
            test_case.assertEqual(len(matching), 1, f"missing unique lockfile pin for {location}")
            state = matching[0].get("state", {})
            test_case.assertEqual(state.get("version"), version, location)
            test_case.assertRegex(state.get("revision", ""), r"^[0-9a-f]{40}$", location)
            test_case.assertNotIn("branch", state, location)

        for pin in pins:
            state = pin.get("state", {})
            test_case.assertTrue(state.get("version"), f"lockfile pin is not versioned: {pin}")
            test_case.assertRegex(state.get("revision", ""), r"^[0-9a-f]{40}$", pin.get("identity"))
            test_case.assertNotIn("branch", state, pin.get("identity"))

    def test_every_external_swift_package_dependency_matches_an_exact_lockfile_pin(self):
        self.assert_exact_package_pins(
            self,
            (REPO / "Package.swift").read_text(),
            json.loads((REPO / "Package.resolved").read_text()),
        )

    def test_dependency_pin_guard_rejects_floating_manifest_requirements(self):
        with self.assertRaisesRegex(AssertionError, "must use an exact version"):
            self.assert_exact_package_pins(
                self,
                'dependencies: [.package(url: "https://example.test/Lib", from: "1.2.3")]',
                {"pins": []},
            )

    def test_dmg_layout_generator_rejects_symlink_output_without_touching_target(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "outside.ds_store"
            target.write_text("preserve this", encoding="utf-8")
            output = root / ".DS_Store"
            output.symlink_to(target)

            with patch.object(DMG_LAYOUT.DSStore, "open") as open_store:
                with self.assertRaisesRegex(ValueError, "DMG layout output must not be a symlink"):
                    DMG_LAYOUT.main(output)
                open_store.assert_not_called()

            self.assertEqual(target.read_text(encoding="utf-8"), "preserve this")

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
