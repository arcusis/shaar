import importlib.util
import json
import re
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/test-native-bitwarden-key-clear.py"
SPEC = importlib.util.spec_from_file_location("native_bitwarden_key_clear", SCRIPT)
assert SPEC and SPEC.loader
RUNNER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = RUNNER
SPEC.loader.exec_module(RUNNER)


class NativeKeyClearProofTests(unittest.TestCase):
    def test_pin_binds_auth_and_candidate_patches(self):
        accepted = json.loads((ROOT / "ThirdParty/BitwardenKeyClearSpike/pin.json").read_text())["accepted"]
        pin, auth_patch, clear_patch = RUNNER.read_pin(candidate=not accepted)
        self.assertIs(type(pin["accepted"]), bool)
        with self.assertRaises(RUNNER.ProofError):
            RUNNER.read_pin(candidate=accepted)
        self.assertTrue(auth_patch.is_file())
        self.assertTrue(clear_patch.is_file())
        patch_paths = set(re.findall(
            r"^diff --git a/(.*?) b/", clear_patch.read_text(encoding="utf-8"), re.M
        ))
        self.assertEqual(
            patch_paths,
            {
                "crates/bitwarden-core/src/key_management/crypto_client.rs",
                "crates/bitwarden-uniffi/src/crypto.rs",
            },
        )

    def test_pinned_fixture_parser_extracts_only_expected_fields(self):
        source = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, source)
        path = source / "crates/bitwarden-core/src/client/test_accounts.rs"
        path.parent.mkdir(parents=True)
        path.write_text(
            '''pub fn test_bitwarden_com_account() {
                user_id: Some(UserId::new(uuid::uuid!("00000000-0000-4000-8000-000000000001"))),
                account_cryptographic_state: WrappedAccountCryptographicState::V1 {
                    private_key: "fixture-private".parse::<EncString>().unwrap(),
                },
                master_key_wrapped_user_key: "fixture-wrapped".parse().unwrap(),
                method: InitUserCryptoMethod::MasterPasswordUnlock {
                    password: "fixture-password".to_owned(),
                },
            }
            pub fn test_bitwarden_com_account_v2() {}
            ''',
            encoding="utf-8",
        )
        fixture = RUNNER.fixture_values(source)
        self.assertEqual(
            set(fixture),
            {"userId", "email", "password", "privateKey", "masterKeyWrappedUserKey", "iterations"},
        )
        self.assertEqual(fixture["email"], "test@bitwarden.com")
        self.assertEqual(fixture["iterations"], 600000)

    def test_receipt_writer_uses_private_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "receipt.json"
            RUNNER.write_private_json(path, {"scope": "test"})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(path.read_text()), {"scope": "test"})

    def test_rejects_malformed_revoked_or_changed_inputs(self):
        for case in ("boolean_schema", "integer_acceptance", "patch_escape", "revoked_auth", "changed_patch"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                for directory, names in (
                    ("BitwardenKeyClearSpike", ("pin.json", "clear-crypto-keys.patch")),
                    ("BitwardenAuthSpike", ("pin.json", "identity-mfa.patch")),
                ):
                    target = root / "ThirdParty" / directory
                    target.mkdir(parents=True)
                    for name in names:
                        shutil.copy2(ROOT / "ThirdParty" / directory / name, target / name)
                path = root / "ThirdParty/BitwardenKeyClearSpike/pin.json"
                pin = json.loads(path.read_text())
                candidate = not pin["accepted"]
                if case == "boolean_schema":
                    pin["schema"] = True
                elif case == "integer_acceptance":
                    pin["accepted"] = 1
                elif case == "patch_escape":
                    pin["patchFile"] = "../BitwardenAuthSpike/identity-mfa.patch"
                elif case == "revoked_auth":
                    auth = root / "ThirdParty/BitwardenAuthSpike/pin.json"
                    data = json.loads(auth.read_text())
                    data["accepted"] = False
                    auth.write_text(json.dumps(data))
                else:
                    patch = path.parent / "clear-crypto-keys.patch"
                    patch.write_bytes(patch.read_bytes() + b"changed")
                path.write_text(json.dumps(pin))
                with mock.patch.object(RUNNER, "ROOT", root), self.assertRaises(RUNNER.ProofError):
                    RUNNER.read_pin(candidate=candidate)


if __name__ == "__main__":
    unittest.main()
