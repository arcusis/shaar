import http.client
import importlib.util
import json
import shutil
import tempfile
import threading
import unittest
from pathlib import Path
from urllib.parse import urlencode
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "native_bitwarden_lifecycle", ROOT / "scripts/test-native-bitwarden-lifecycle.py"
)
assert SPEC and SPEC.loader
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class LifecycleBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        third_party = self.root / "ThirdParty"
        third_party.mkdir()
        for name in ("BitwardenLifecycleProbe", "BitwardenAuthSpike",
                     "BitwardenKeyClearSpike", "BitwardenSyncSpike"):
            shutil.copytree(ROOT / "ThirdParty" / name, third_party / name)
        test_pin_path = third_party / "BitwardenLifecycleProbe/pin.json"
        test_pin = json.loads(test_pin_path.read_text(encoding="utf-8"))
        test_pin["accepted"] = False
        test_pin_path.write_text(json.dumps(test_pin), encoding="utf-8")
        self.root_patch = mock.patch.object(RUNNER, "ROOT", self.root)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)
        self.pin_patch = mock.patch.object(
            RUNNER, "PIN_PATH", third_party / "BitwardenLifecycleProbe/pin.json")
        self.pin_patch.start()
        self.addCleanup(self.pin_patch.stop)

    def read_pin_json(self):
        path = RUNNER.PIN_PATH
        return json.loads(path.read_text(encoding="utf-8"))

    def write_pin_json(self, value):
        RUNNER.PIN_PATH.write_text(json.dumps(value), encoding="utf-8")

    def test_candidate_and_default_pin_modes_are_strict(self):
        with self.assertRaises(RUNNER.ProofError):
            RUNNER.read_pin(candidate=False)
        pin, patches = RUNNER.read_pin(candidate=True)
        self.assertIs(pin["accepted"], False)
        self.assertEqual(set(patches), {"auth", "clear", "sync"})
        promoted = self.read_pin_json()
        promoted["accepted"] = True
        self.write_pin_json(promoted)
        RUNNER.read_pin(candidate=False)
        with self.assertRaises(RUNNER.ProofError):
            RUNNER.read_pin(candidate=True)

    def test_malformed_schemas_booleans_targets_patch_hashes_and_paths_rejected(self):
        for name, change in (
            ("boolean_schema", lambda p: p.update(schema=True)),
            ("integer_accepted", lambda p: p.update(accepted=1)),
            ("enabled_integration", lambda p: p.update(integration_ready=True)),
            ("wrong_target", lambda p: p.update(target="x86_64-apple-darwin")),
            ("wrong_lock", lambda p: p.update(candidateCargoLockSHA256="0" * 64)),
            ("wrong_patch", lambda p: p.update(syncPatchSHA256="0" * 64)),
            ("wrong_changed_file_count", lambda p: p.update(changedFiles=True)),
            ("wrong_changed_paths", lambda p: p.update(changedPaths=["../escape"])),
            ("tls_claim", lambda p: p.update(tlsAuthorityBindingAccepted=True)),
        ):
            with self.subTest(name=name):
                pin = self.read_pin_json()
                change(pin)
                self.write_pin_json(pin)
                with self.assertRaises(RUNNER.ProofError):
                    RUNNER.read_pin(candidate=True)

    def test_changed_patch_bytes_and_symlinked_patch_rejected(self):
        patch = RUNNER.ROOT / "ThirdParty/BitwardenKeyClearSpike/clear-crypto-keys.patch"
        original = patch.read_bytes()
        patch.write_bytes(original + b"\nchanged")
        with self.assertRaises(RUNNER.ProofError):
            RUNNER.read_pin(candidate=True)
        patch.write_bytes(original)
        external = self.root / "patch-copy"
        external.write_bytes(original)
        patch.unlink()
        patch.symlink_to(external)
        with self.assertRaises(RUNNER.ProofError):
            RUNNER.read_pin(candidate=True)

    def test_private_root_and_receipt_modes_and_redaction(self):
        root = self.root / "proof"
        RUNNER.create_private_root(root)
        self.assertEqual(root.stat().st_mode & 0o777, 0o700)
        receipt = {"schema": 1, "status": "candidate_succeeded",
                   "stages": {"sdk_sync_fetched_cipher": True}}
        RUNNER.write_receipt(root, receipt)
        path = root / "receipt.json"
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads(path.read_text()), receipt)
        self.assertFalse((root / "receipt.json.tmp").exists())
        with self.assertRaises(RUNNER.ProofError):
            RUNNER.write_receipt(root, {"access_token": "synthetic-secret"})
        with self.assertRaises(FileExistsError):
            RUNNER.create_private_root(root)
        path.unlink()
        root.chmod(0o755)
        with self.assertRaises(RUNNER.ProofError):
            RUNNER.write_receipt(root, receipt)

    def test_native_stage_validation_rejects_missing_or_wrong_binding(self):
        output = "\n".join(
            f"{RUNNER.LIFECYCLE_STAGE_MARKER}{stage}=passed"
            for stage in sorted(RUNNER.REQUIRED_STAGES)
        ) + "\n" + RUNNER.LIFECYCLE_COMPLETION_MARKER
        mock_state = {"validSyncAuthorization": True, "syncRequests": 1,
                      "lateResponsesHeld": 3, "lateResponsesReleased": 3}
        self.assertTrue(all(RUNNER.validate_stage_output(output, mock_state).values()))
        missing = output.replace(
            f"{RUNNER.LIFECYCLE_STAGE_MARKER}disabled_late_commit_rejected=passed\n", "")
        self.assertFalse(
            RUNNER.validate_stage_output(missing, mock_state)["disabled_late_commit_rejected"])
        wrong_binding = output.replace(
            f"{RUNNER.LIFECYCLE_STAGE_MARKER}gate_store_token_commit=passed",
            f"{RUNNER.LIFECYCLE_STAGE_MARKER}gate_store_token_commit=failed")
        self.assertFalse(
            RUNNER.validate_stage_output(wrong_binding, mock_state)["gate_store_token_commit"])
        duplicate = output + (
            f"\n{RUNNER.LIFECYCLE_STAGE_MARKER}rebound_late_commit_rejected=failed\n")
        self.assertFalse(
            RUNNER.validate_stage_output(duplicate, mock_state)["rebound_late_commit_rejected"])
        self.assertFalse(RUNNER.validate_stage_output(output, {
            "validSyncAuthorization": False, "syncRequests": 1
        })["mock_sdk_token_observed"])
        insufficient_holds = {**mock_state, "lateResponsesHeld": 2,
                              "lateResponsesReleased": 2}
        stages = RUNNER.validate_stage_output(output, insufficient_holds)
        self.assertFalse(stages["disabled_late_commit_rejected"])
        self.assertFalse(stages["rebound_late_commit_rejected"])

    def test_fixture_preparation_shape_and_rust_counts_validated(self):
        with self.assertRaises(RUNNER.ProofError):
            RUNNER.prepared_output(b'{"passwordHash":"x"}')
        with self.assertRaises(RUNNER.ProofError):
            RUNNER.prepared_output(b'{"passwordHash":"x","newKey":"y",'
                                   b'"encryptedCipherBase64":""}')
        payload = (b'{"passwordHash":"opaque","newKey":"opaque",'
                   b'"encryptedCipherBase64":"opaque"}')
        valid = RUNNER.PREPARED_OUTPUT_MARKER + payload
        self.assertEqual(
            RUNNER.prepared_output(b"unrelated SDK log\n" + valid + b"\nmore SDK log"),
            {"passwordHash": "opaque", "newKey": "opaque",
             "encryptedCipherBase64": "opaque"},
        )
        for invalid in (
            payload, b"prefix " + valid, valid + b"\n" + valid,
            RUNNER.PREPARED_OUTPUT_MARKER + b'{"passwordHash":"x",',
            RUNNER.PREPARED_OUTPUT_MARKER +
            b'{"passwordHash":"x","passwordHash":"y","newKey":"z",'
            b'"encryptedCipherBase64":"w"}',
            valid + b"\xff", b"x" * (RUNNER.MAX_NATIVE_OUTPUT_BYTES + 1),
        ):
            with self.subTest(output_length=len(invalid)):
                with self.assertRaises(RUNNER.ProofError):
                    RUNNER.prepared_output(invalid)
        self.assertEqual(RUNNER.parse_test_count(
            "test result: ok. 3 passed; 0 failed; 0 ignored;\n"
            "test result: ok. 2 passed; 0 failed; 0 ignored;"), (5, 0, 2))
        self.assertEqual(RUNNER.parse_test_count("test result: FAILED. 1 passed; 1 failed;"),
                         (0, 1, 1))
        for returncode, counts in (
            (0, (0, 0, 0)),
            (0, (0, 0, 1)),
            (0, (1, 1, 1)),
            (101, (1, 0, 1)),
        ):
            with self.subTest(returncode=returncode, counts=counts):
                with self.assertRaises(RUNNER.ProofError):
                    RUNNER.validate_rust_regression(returncode, counts, "rust_regression")
        self.assertEqual(
            RUNNER.validate_rust_regression(
                0, (3, 0, 1), "rust_regression"),
            (3, 0, 1),
        )

    def test_ownership_stages_require_held_late_responses_and_valid_sync_binding(self):
        output = "\n".join(
            f"{RUNNER.LIFECYCLE_STAGE_MARKER}{stage}=passed"
            for stage in sorted(RUNNER.REQUIRED_STAGES)
        ) + "\n" + RUNNER.LIFECYCLE_COMPLETION_MARKER
        valid = {"validSyncAuthorization": True, "syncRequests": 1,
                 "lateResponsesHeld": 3, "lateResponsesReleased": 3}
        output = "SDK log line\n" + output
        stages = RUNNER.validate_stage_output(output, valid)
        self.assertTrue(stages["mock_sdk_token_observed"])
        self.assertTrue(stages["disabled_late_commit_rejected"])
        self.assertTrue(stages["rebound_late_commit_rejected"])
        for changed in ({**valid, "validSyncAuthorization": False},
                        {**valid, "syncRequests": 2}):
            with self.subTest(state=changed):
                self.assertFalse(
                    RUNNER.validate_stage_output(output, changed)["mock_sdk_token_observed"])
        for changed in ({**valid, "lateResponsesHeld": 2},
                        {**valid, "lateResponsesReleased": 2}):
            with self.subTest(state=changed):
                stages = RUNNER.validate_stage_output(output, changed)
                self.assertFalse(stages["disabled_late_commit_rejected"])
                self.assertFalse(stages["rebound_late_commit_rejected"])

    def test_lifecycle_protocol_requires_unique_stages_and_complete_bounded_frame(self):
        output = "\n".join(
            f"{RUNNER.LIFECYCLE_STAGE_MARKER}{stage}=passed"
            for stage in sorted(RUNNER.REQUIRED_STAGES)
        ) + "\n" + RUNNER.LIFECYCLE_COMPLETION_MARKER
        state = {"validSyncAuthorization": True, "syncRequests": 1,
                 "lateResponsesHeld": 3, "lateResponsesReleased": 3}
        self.assertTrue(all(RUNNER.validate_stage_output(
            "unrelated SDK diagnostic\n" + output, state).values()))
        for invalid in (
            output.replace(RUNNER.LIFECYCLE_COMPLETION_MARKER, ""),
            output + "\n" + RUNNER.LIFECYCLE_COMPLETION_MARKER,
            output + f"\n{RUNNER.LIFECYCLE_STAGE_MARKER}sdk_password_login=passed",
            output + "x" * RUNNER.MAX_NATIVE_OUTPUT_BYTES,
        ):
            with self.subTest(length=len(invalid)):
                self.assertFalse(all(RUNNER.validate_stage_output(invalid, state).values()))
        counts = RUNNER.observed_mock_counts({
            "preloginRequests": 5, "validLoginRequests": 4,
            "rejectedLoginRequests": 1, "syncRequests": 1,
            "lateResponsesHeld": 3, "lateResponsesReleased": 3,
        })
        self.assertEqual(counts, RUNNER.EXPECTED_MOCK_COUNTS)

    def test_preflight_rejects_invalid_target_and_args_before_rust_commands(self):
        output = self.root / "fresh-output"
        args = type("Args", (), {
            "candidate": True, "source": self.root / "missing-source", "output": output,
        })()
        with mock.patch.object(RUNNER.platform, "system", return_value="Darwin"), \
                mock.patch.object(RUNNER.platform, "machine", return_value="arm64"), \
                mock.patch.object(RUNNER, "run_command") as command, \
                self.assertRaises(RUNNER.ProofError):
            RUNNER.preflight(args)
        command.assert_not_called()
        self.assertFalse(output.exists())

        existing = self.root / "existing"
        existing.mkdir()
        args.output = existing
        with mock.patch.object(RUNNER.platform, "system", return_value="Darwin"), \
                mock.patch.object(RUNNER.platform, "machine", return_value="arm64"), \
                mock.patch.object(RUNNER, "run_command") as command, \
                self.assertRaises(RUNNER.ProofError):
            RUNNER.preflight(args)
        command.assert_not_called()

    def test_mock_server_rejects_wrong_login_and_unowned_sync_token(self):
        RUNNER.MockHandler.state = {
            "email": "synthetic@example.invalid", "iterations": 600_000,
            "passwordHash": "expected-hash-kept-in-memory",
            "accessToken": "expected-token-kept-in-memory",
            "loginResponse": {}, "syncResponse": {}, "preloginRequests": 0,
            "validLoginRequests": 0, "rejectedLoginRequests": 0,
            "syncRequests": 0, "validSyncAuthorization": False,
        }
        server = RUNNER.OwnedServer(("127.0.0.1", 0), RUNNER.MockHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        address = server.server_address
        connection = http.client.HTTPConnection(address[0], address[1], timeout=3)
        try:
            connection.request("GET", "/api/sync")
            response = connection.getresponse()
            self.assertEqual(response.status, 401)
            response.read()
            self.assertEqual(RUNNER.MockHandler.state["syncRequests"], 1)
            self.assertFalse(RUNNER.MockHandler.state["validSyncAuthorization"])
            connection.request(
                "POST", "/identity/connect/token", body=b"client_id=wrong",
                headers={"Content-Type": "application/x-www-form-urlencoded"})
            response = connection.getresponse()
            self.assertEqual(response.status, 400)
            response.read()
            self.assertEqual(RUNNER.MockHandler.state["rejectedLoginRequests"], 1)
        finally:
            connection.close()
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)
        self.assertFalse(thread.is_alive())
        self.assertTrue(RUNNER.listener_refused(address))

    def test_mock_holds_actual_login_response_until_host_releases_it(self):
        RUNNER.MockHandler.state = {
            "email": "synthetic@example.invalid", "iterations": 600_000,
            "passwordHash": "expected-hash-kept-in-memory", "loginResponse": {},
            "validLoginRequests": 1, "rejectedLoginRequests": 0,
            "lateLoginWaiting": threading.Event(), "releaseLateLogin": threading.Event(),
            "lateResponseFinished": threading.Event(),
            "lateResponsesHeld": 0, "lateResponsesReleased": 0,
        }
        server = RUNNER.OwnedServer(("127.0.0.1", 0), RUNNER.MockHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        address = server.server_address
        response_done = threading.Event()
        response_status = []

        def issue_login():
            connection = http.client.HTTPConnection(address[0], address[1], timeout=5)
            try:
                body = urlencode({
                    "client_id": "arcusis-browser-synthetic-probe",
                    "deviceIdentifier": "00000000-0000-4000-8000-000000000026",
                    "deviceName": "Synthetic Swift Probe", "deviceType": "21",
                    "username": "synthetic@example.invalid",
                    "password": "expected-hash-kept-in-memory",
                })
                connection.request(
                    "POST", "/identity/connect/token", body=body,
                    headers={"Content-Type": "application/x-www-form-urlencoded"})
                response = connection.getresponse()
                response_status.append(response.status)
                response.read()
            finally:
                connection.close()
                response_done.set()

        client_thread = threading.Thread(target=issue_login)
        client_thread.start()
        try:
            self.assertTrue(RUNNER.MockHandler.state["lateLoginWaiting"].wait(3))
            self.assertFalse(response_done.is_set())
            release = http.client.HTTPConnection(address[0], address[1], timeout=3)
            try:
                release.request("POST", "/probe/release-late-login")
                control = release.getresponse()
                self.assertEqual(control.status, 200)
                control.read()
            finally:
                release.close()
            self.assertTrue(response_done.wait(3))
            self.assertEqual(response_status, [200])
            self.assertEqual(RUNNER.MockHandler.state["lateResponsesHeld"], 1)
            self.assertEqual(RUNNER.MockHandler.state["lateResponsesReleased"], 1)
        finally:
            RUNNER.MockHandler.state["releaseLateLogin"].set()
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)
            client_thread.join(timeout=3)
        self.assertFalse(thread.is_alive())
        self.assertTrue(RUNNER.listener_refused(address))

    def test_cleanup_failure_is_observed(self):
        work = self.root / "work"
        work.mkdir(mode=0o700)
        with mock.patch.object(RUNNER.shutil, "rmtree"):
            self.assertFalse(RUNNER.remove_private_work(work))
        self.assertTrue(work.exists())
        self.assertTrue(RUNNER.remove_private_work(work))
        self.assertFalse(work.exists())

    def test_only_bound_build_artifacts_survive_private_work_cleanup(self):
        work = self.root / "private-work"
        generated = work / "GeneratedSwift"
        generated.mkdir(parents=True, mode=0o700)
        (generated / "BitwardenSdk.swift").write_text("public struct GeneratedBinding {}\n")
        dylib = work / "cargo-target/aarch64-apple-darwin/debug/libbitwarden_uniffi.dylib"
        dylib.parent.mkdir(parents=True)
        dylib.write_bytes(b"synthetic compiled library bytes")
        bindgen = work / "cargo-target/debug/uniffi-bindgen"
        bindgen.parent.mkdir(parents=True)
        bindgen.write_bytes(b"synthetic bindgen executable")
        output = self.root / "private-output"
        RUNNER.create_private_root(output)
        receipt = {"artifacts": {"probeMainSHA256": "source-digest"}}

        RUNNER.preserve_build_artifacts(work, output, receipt)

        artifacts = output / "artifacts"
        self.assertEqual(artifacts.stat().st_mode & 0o777, 0o700)
        self.assertEqual((artifacts / "libbitwarden_uniffi.dylib").stat().st_mode & 0o777,
                         0o600)
        self.assertEqual(receipt["artifacts"]["dylibSHA256"],
                         RUNNER.sha256(artifacts / "libbitwarden_uniffi.dylib"))
        self.assertEqual(receipt["artifacts"]["generatedSwiftTreeSHA256"],
                         RUNNER.tree_sha(artifacts / "GeneratedSwift"))
        self.assertEqual(receipt["artifacts"]["sourcePatchBinding"]["sourceCommit"],
                         RUNNER.SOURCE_COMMIT)
        self.assertEqual(receipt["artifacts"]["uniffiBindgen"]["sha256"],
                         RUNNER.sha256(artifacts / "uniffi-bindgen"))
        self.assertTrue(RUNNER.remove_private_work(work))
        self.assertTrue((artifacts / "GeneratedSwift/BitwardenSdk.swift").is_file())
        self.assertFalse((artifacts / "private-work").exists())


if __name__ == "__main__":
    unittest.main()
