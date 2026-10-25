import argparse
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "native_session_runner", ROOT / "scripts/test-native-bitwarden-session.py"
)
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class NativeSessionInputTests(unittest.TestCase):
    def test_owned_endpoint_only(self):
        self.assertTrue(runner.is_owned_endpoint("http://127.0.0.1:43123/"))
        for endpoint in (
            "https://127.0.0.1:43123/", "http://localhost:43123/",
            "http://127.0.0.1:43123/path", "http://127.0.0.1:43123/?token=x",
            "http://user@127.0.0.1:43123/", "http://127.0.0.1/",
        ):
            with self.subTest(endpoint=endpoint):
                self.assertFalse(runner.is_owned_endpoint(endpoint))

    def test_public_sdk_vector_is_read_from_pristine_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)
            vector_path = source / "crates/bitwarden-core/src/client/test_accounts.rs"
            vector_path.parent.mkdir(parents=True)
            vector_path.write_text(
                'pub fn test_bitwarden_com_account() -> TestAccount {\n'
                'let kdf = Kdf::PBKDF2 { iterations: 600_000.try_into().unwrap() };\n'
                'user_id: Some(UserId::new(uuid::uuid!("060000fb-0922-4dd3-b170-6e15cb5df8c8"))),\n'
                'let email = "test@bitwarden.com";\n'
                'private_key: "wrapped-private".parse::<EncString>().unwrap(),\n'
                'password: "source-vector-password".to_owned(),\n'
                'master_key_wrapped_user_key: "wrapped-user-key".parse().unwrap(),\n'
                '}\n/// ### V2 `test@bitwarden.com`\n', encoding="utf-8")
            vector = runner.sdk_vector(source)
        self.assertEqual(vector, {
            "userID": "060000fb-0922-4dd3-b170-6e15cb5df8c8",
            "email": "test@bitwarden.com", "currentPassword": "source-vector-password",
            "privateKey": "wrapped-private", "wrappedUserKey": "wrapped-user-key",
            "iterations": 600000,
        })

    def test_vector_path_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            source.mkdir()
            outside = root / "vector.rs"
            outside.write_text("fixture", encoding="utf-8")
            target = source / "crates/bitwarden-core/src/client/test_accounts.rs"
            target.parent.mkdir(parents=True)
            target.symlink_to(outside)
            with self.assertRaises(runner.ProofError):
                runner.sdk_vector(source)

    def test_output_requires_fresh_path_and_existing_parent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            existing = root / "existing"
            existing.mkdir()
            args = argparse.Namespace(
                proof_root=root / "missing-proof", source=root / "missing-source",
                output=existing)
            with mock.patch.object(runner.platform, "system", return_value="Darwin"), \
                    mock.patch.object(runner.platform, "machine", return_value="arm64"), \
                    self.assertRaises(runner.ProofError):
                runner.run(args)
            args.output = root / "missing-parent" / "receipt"
            with mock.patch.object(runner.platform, "system", return_value="Darwin"), \
                    mock.patch.object(runner.platform, "machine", return_value="arm64"), \
                    self.assertRaises(runner.ProofError):
                runner.run(args)

    def test_receipt_is_private_and_atomically_replaced(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "proof"
            receipt = {"schema": 1, "integration_ready": False}
            runner.write_private_receipt(output, receipt)
            path = output / "receipt.json"
            self.assertEqual(output.stat().st_mode & 0o777, 0o700)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(path.read_text()), receipt)
            self.assertFalse((output / "receipt.json.tmp").exists())


if __name__ == "__main__":
    unittest.main()
