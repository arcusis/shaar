# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Developer ID passkey entitlements stay out of a release until Apple's profile is present."""

import importlib.util
import plistlib
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("passkey_signing", REPO / "scripts" / "passkey_signing.py")
passkey_signing = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = passkey_signing
SPEC.loader.exec_module(passkey_signing)
AVAILABILITY = importlib.util.spec_from_file_location(
    "test_passkey_availability", REPO / "scripts" / "test-passkey-availability.py")
availability = importlib.util.module_from_spec(AVAILABILITY)
sys.modules[AVAILABILITY.name] = availability
AVAILABILITY.loader.exec_module(availability)

PASSKEYS = REPO / "Resources/Signing/Passkeys.entitlements"
BASE = REPO / "Resources/Signing/Shaar.entitlements"


def future():
    return datetime.now(timezone.utc) + timedelta(days=30)


def valid_profile():
    entitlements = passkey_signing.required_entitlements()
    entitlements["com.apple.developer.associated-domains"] = ["webcredentials:example.test"]
    return {
        "TeamIdentifier": [passkey_signing.TEAM_ID],
        "ApplicationIdentifierPrefix": [passkey_signing.TEAM_ID],
        "ProvisionsAllDevices": True,
        "Platform": ["OSX"],
        "ExpirationDate": future(),
        "Entitlements": entitlements,
    }


class PasskeySigningTests(unittest.TestCase):
    def test_passkeys_plist_matches_the_release_contract(self):
        plist = plistlib.loads(PASSKEYS.read_bytes())
        self.assertEqual(plist, passkey_signing.required_entitlements())
        self.assertEqual(passkey_signing.APPLICATION_IDENTIFIER, "F9Z784RA6D.com.arcusis.browser")
        self.assertEqual(
            passkey_signing.KEYCHAIN_ACCESS_GROUP, "F9Z784RA6D.com.arcusis.shaar.engine.webauthn")

    def test_valid_profile_merges_passkeys_onto_the_base_entitlements(self):
        with tempfile.TemporaryDirectory() as temporary:
            decoded = Path(temporary) / "profile.plist"
            output = Path(temporary) / "merged.plist"
            decoded.write_bytes(plistlib.dumps(valid_profile()))
            result = subprocess.run(
                [sys.executable, str(REPO / "scripts" / "passkey_signing.py"), "merge",
                 "--base", str(BASE), "--passkeys", str(PASSKEYS),
                 "--profile-plist", str(decoded), "--output", str(output)],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            merged = plistlib.loads(output.read_bytes())
        base = plistlib.loads(BASE.read_bytes())
        for key, value in base.items():
            self.assertEqual(merged[key], value)
        for key, value in passkey_signing.required_entitlements().items():
            self.assertEqual(merged[key], value)
        self.assertIn("com.apple.security.device.camera", merged)

    def test_check_accepts_a_decoded_developer_id_profile(self):
        self.assertEqual(passkey_signing.profile_problems(valid_profile()), [])

    def test_rejections(self):
        cases = {
            "wrong team": ("TeamIdentifier", ["OTHERTEAM1"]),
            "development devices": ("ProvisionedDevices", ["device"]),
            "missing developer id marker": ("ProvisionsAllDevices", False),
            "expired": ("ExpirationDate", datetime(2020, 1, 1, tzinfo=timezone.utc)),
        }
        for name, (key, value) in cases.items():
            with self.subTest(name=name):
                profile = valid_profile()
                profile[key] = value
                self.assertTrue(passkey_signing.profile_problems(profile))

    def test_entitlement_mismatches(self):
        profile = valid_profile()
        profile["Entitlements"].pop(passkey_signing.BROWSER_ENTITLEMENT)
        self.assertIn(
            f"profile is missing {passkey_signing.BROWSER_ENTITLEMENT}",
            passkey_signing.profile_problems(profile))
        profile = valid_profile()
        profile["Entitlements"][passkey_signing.BROWSER_ENTITLEMENT] = 1
        self.assertTrue(any(
            passkey_signing.BROWSER_ENTITLEMENT in problem
            for problem in passkey_signing.profile_problems(profile)))
        profile = valid_profile()
        profile["Entitlements"]["keychain-access-groups"] = [".com.arcusis.shaar.engine.webauthn"]
        self.assertTrue(any("keychain-access-groups" in problem
                            for problem in passkey_signing.profile_problems(profile)))
        profile = valid_profile()
        profile["Entitlements"]["com.apple.developer.team-identifier"] = "OTHERTEAM1"
        self.assertTrue(any("team-identifier" in problem
                            for problem in passkey_signing.profile_problems(profile)))
        profile = valid_profile()
        profile["Entitlements"]["com.apple.security.get-task-allow"] = True
        self.assertIn("profile allows a debugger", passkey_signing.profile_problems(profile))

    def test_profile_rejects_malformed_debugger_entitlement_values(self):
        for value in (1, 0, "false", None, [False]):
            with self.subTest(value=value):
                profile = valid_profile()
                profile["Entitlements"]["com.apple.security.get-task-allow"] = value
                self.assertIn(
                    "profile has an invalid debugger entitlement",
                    passkey_signing.profile_problems(profile),
                )

    def test_merge_refuses_a_key_the_base_already_has(self):
        profile = valid_profile()
        base = plistlib.loads(BASE.read_bytes())
        base[passkey_signing.BROWSER_ENTITLEMENT] = True
        with self.assertRaises(ValueError):
            passkey_signing.merged_entitlements(base, passkey_signing.required_entitlements())
        self.assertEqual(passkey_signing.profile_problems(profile), [])

    def test_release_checks_the_profile_after_the_signing_identity(self):
        text = (REPO / "scripts" / "release.sh").read_text()
        identity = text.index("signing identity not found")
        check = text.index("passkey_signing.py check")
        build = text.index("bash scripts/bundle-app.sh")
        merge = text.index("passkey_signing.py merge")
        embed = text.index('"$app/Contents/embedded.provisionprofile"')
        sign = text.index('sign --entitlements "$app_entitlements" "$app"')
        self.assertLess(identity, check)
        self.assertLess(check, build)
        self.assertLess(build, merge)
        self.assertLess(merge, embed)
        self.assertLess(embed, sign)
        self.assertNotIn("security cms", text)
        self.assertIn("Signing without iCloud Keychain passkeys", text)
        bundle = (REPO / "scripts" / "bundle-app.sh").read_text()
        self.assertNotIn("Passkeys.entitlements", bundle)
        self.assertNotIn("web-browser.public-key-credential", bundle)

    def test_cstring_scan_does_not_treat_the_team_group_as_the_empty_group(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / "framework"
            binary.write_bytes(
                b"\0.com.arcusis.shaar.engine.webauthn\0"
                b"\0F9Z784RA6D.com.arcusis.shaar.engine.webauthn\0"
                b"\0com.apple.developer.web-browser.public-key-credential\0"
            )
            self.assertTrue(availability.contains_cstring(binary, ".com.arcusis.shaar.engine.webauthn"))
            self.assertTrue(availability.contains_cstring(
                binary, "F9Z784RA6D.com.arcusis.shaar.engine.webauthn"))
            self.assertTrue(availability.contains_cstring(
                binary, "com.apple.developer.web-browser.public-key-credential"))
            team_only = Path(temporary) / "team-only"
            team_only.write_bytes(b"\0F9Z784RA6D.com.arcusis.shaar.engine.webauthn\0")
            self.assertFalse(availability.contains_cstring(team_only, ".com.arcusis.shaar.engine.webauthn"))

    def test_adhoc_probe_refuses_a_passkey_signature(self):
        adhoc = "Signature=adhoc\nTeamIdentifier=not set\n"
        self.assertIsNone(availability.adhoc_without_passkey_entitlements(adhoc, ""))
        self.assertEqual(
            availability.adhoc_without_passkey_entitlements("Signature=adhoc\nTeamIdentifier=F9Z784RA6D\n", ""),
            "signature is not ad-hoc")
        self.assertEqual(
            availability.adhoc_without_passkey_entitlements(adhoc, passkey_signing.BROWSER_ENTITLEMENT),
            "browser passkey entitlement is present")
        self.assertEqual(
            availability.adhoc_without_passkey_entitlements(adhoc, "keychain-access-groups"),
            "keychain-access-groups is present")


if __name__ == "__main__":
    unittest.main()
