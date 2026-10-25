from __future__ import annotations

import hashlib
import importlib.util
import json
import shutil
import stat
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "native_bitwarden_sync_runner", ROOT / "scripts/test-native-bitwarden-sync.py"
)
assert SPEC is not None and SPEC.loader is not None
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class SyncRunnerBehaviorTests(unittest.TestCase):
    def test_owned_endpoint_accepts_only_plain_loopback_root(self):
        self.assertTrue(RUNNER.owned_endpoint("http://127.0.0.1:45678/"))
        for value in (
            "https://127.0.0.1:45678/",
            "http://localhost:45678/",
            "http://example.test:45678/",
            "http://user@127.0.0.1:45678/",
            "http://127.0.0.1:45678/?q=x",
            "http://127.0.0.1:45678/#fragment",
            "http://127.0.0.1:45678/api",
            "http://127.0.0.1:not-a-port/",
            "http://127.0.0.1/",
        ):
            with self.subTest(value=value):
                self.assertFalse(RUNNER.owned_endpoint(value))

    def test_prepared_fixture_accepts_cipher_only(self):
        fixture = RUNNER.prepared_fixture(b"ready\n{\"cipher\":{\"type\":1}}\n")
        self.assertEqual(fixture, {"cipher": {"type": 1}})
        for value in (b"", b"not-json", b"{}", b"{\"cipher\":null}", b"{\"cipher\":[]}"):
            with self.subTest(value=value):
                with self.assertRaises(RUNNER.ProofError):
                    RUNNER.prepared_fixture(value)

    def test_receipt_is_private_and_round_trips(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "private-proof"
            output.mkdir(mode=0o700)
            receipt = {"schema": 1, "stageLabels": {"sync": True}}
            RUNNER.write_receipt(output, receipt)
            path = output / "receipt.json"
            self.assertEqual(json.loads(path.read_text()), receipt)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_zero_test_count_never_counts_as_pass(self):
        self.assertEqual(RUNNER.parse_test_count("test result: ok. 0 passed; 0 failed;"), 0)
        self.assertFalse(RUNNER.tests_passed(0, "test result: ok. 0 passed; 0 failed;"))
        self.assertFalse(RUNNER.tests_passed(101, "test result: ok. 12 passed; 0 failed;"))
        self.assertTrue(RUNNER.tests_passed(0, "test result: ok. 12 passed; 0 failed;"))

    def test_pin_validator_rejects_wrong_review_mode_and_mismatched_fields(self):
        original_pin = json.loads((ROOT / "ThirdParty/BitwardenSyncSpike/pin.json").read_text())
        patch_bytes = (ROOT / "ThirdParty/BitwardenSyncSpike/sync.patch").read_bytes()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            patch = root / "sync.patch"
            patch.write_bytes(patch_bytes)
            pin_path = root / "pin.json"

            def write_pin(value):
                pin_path.write_text(json.dumps(value))

            write_pin(original_pin)
            self.assertIs(RUNNER.validate_pin(pin_path, patch)["accepted"], True)
            with self.assertRaises(RUNNER.ProofError):
                RUNNER.validate_pin(pin_path, patch, candidate=True)
            candidate = dict(original_pin, accepted=False)
            write_pin(candidate)
            self.assertIs(RUNNER.validate_pin(pin_path, patch, candidate=True)["accepted"], False)
            with self.assertRaises(RUNNER.ProofError):
                RUNNER.validate_pin(pin_path, patch)
            write_pin(original_pin)
            mutations = (
                {"schema": True},
                {"schema": 2},
                {"accepted": False},
                {"sourceCommit": "0" * 40},
                {"sourceTreeSHA256": "0" * 40},
                {"authPatchSHA256": "0" * 64},
                {"patchSHA256": "0" * 64},
                {"patchBytes": len(patch_bytes) + 1},
                {"changedFiles": 4},
                {"target": "x86_64-unknown-linux-gnu"},
                {"rustToolchain": "stable"},
                {"minMacOS": "25.0"},
                {"integration_ready": True},
            )
            for mutation in mutations:
                candidate = dict(original_pin)
                candidate.update(mutation)
                write_pin(candidate)
                with self.subTest(mutation=mutation):
                    with self.assertRaises(RUNNER.ProofError):
                        RUNNER.validate_pin(pin_path, patch)
            patch.write_bytes(patch_bytes + b" ")
            write_pin(original_pin)
            with self.assertRaises(RUNNER.ProofError):
                RUNNER.validate_pin(pin_path, patch)

    def test_sync_patch_contract_and_snapshot_failure_guards(self):
        patch = (ROOT / "ThirdParty/BitwardenSyncSpike/sync.patch").read_text()
        self.assertIn("on_sync_complete", patch)
        self.assertIn("on_error", patch)
        self.assertIn("Cipher::try_from", patch)
        self.assertIn("pub mod sync;", patch)
        self.assertIn('Error::Conversion("sync failed".to_owned())', patch)
        self.assertNotIn("CipherView {", patch)
        probe = (ROOT / "Tests/NativeBitwardenSyncProbe/main.swift").read_text()
        self.assertIn("afterUnauthorized == originalSnapshot", probe)
        self.assertIn("afterMalformed == originalSnapshot", probe)
        self.assertIn("decryptsExpected(client, cipher:", probe)
        self.assertIn("independentCryptoLocked", probe)
        self.assertIn("independentTokenPreserved", probe)

    def test_scoped_readme_limits_atomicity_and_acceptance_claims(self):
        readme = (ROOT / "ThirdParty/BitwardenSyncSpike/README.md").read_text()
        self.assertIn("integration_ready=false", readme)
        self.assertIn("does not establish organization or full-vault behavior", readme)
        self.assertIn("atomic snapshot only", readme.lower())
        self.assertIn("may mutate their own stores or key state before a later handler fails", readme)
        self.assertIn("TLS, real vendor/server", readme)
        self.assertIn("does not change app licensing", readme)
        self.assertTrue((ROOT / "ThirdParty/BitwardenSyncSpike/LICENSE_GPL.txt").is_file())


if __name__ == "__main__":
    unittest.main()
