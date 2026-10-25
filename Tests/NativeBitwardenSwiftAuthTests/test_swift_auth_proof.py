import http.client
import importlib.util
import json
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "swift_auth_runner", ROOT / "scripts/test-native-bitwarden-swift-auth.py"
)
runner = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(runner)


class SwiftAuthProofBoundaryTests(unittest.TestCase):
    def make_valid_receipt(self, root):
        proof_root = root / "proof"
        source_root = root / "source"
        generated = proof_root / "GeneratedSwift"
        generated.mkdir(parents=True)
        source_root.mkdir()
        dylib = proof_root / "libbitwarden_uniffi.dylib"
        dylib.write_bytes(b"accepted dylib")
        (generated / "Bindings.swift").write_text("accepted bindings")
        support = source_root / "crates/bitwarden-uniffi/swift/Sources/BitwardenSdkSupport"
        support.mkdir(parents=True)
        (support / "NaiveDateFormatter.swift").write_text("support")
        (generated / "BitwardenFFI.modulemap").write_text("module BitwardenFFI {}")
        expected = {
            "schema": 1,
            "status": "succeeded",
            "source": {
                "commit": runner.SOURCE_COMMIT,
                "tree": runner.SOURCE_TREE,
                "cargoLockSHA256": runner.CARGO_LOCK_SHA,
            },
            "patchSHA256": runner.PATCH_SHA,
            "host": {
                "system": "Darwin", "architecture": "arm64",
                "target": "aarch64-apple-darwin", "deploymentTarget": "26.0",
            },
            "artifacts": {
                "dylibPath": str(dylib),
                "generatedSwiftPath": str(generated),
                "dylibSHA256": runner.sha256(dylib),
                "generatedSwiftTreeSHA256": runner.tree_sha(generated),
                "dylibMinimumMacOS": "26.0",
            },
        }
        (proof_root / "receipt.json").write_text(json.dumps(expected))
        git_results = [
            subprocess.CompletedProcess([], 0, runner.SOURCE_COMMIT + "\n", ""),
            subprocess.CompletedProcess([], 0, "", ""),
        ]
        return proof_root, source_root, expected, git_results

    def validate_fixture(self, root, expected=None, git_results=None):
        if expected is None:
            proof_root, source_root, original, default_git = self.make_valid_receipt(root)
            receipt = original
        else:
            proof_root, source_root = root / "proof", root / "source"
            original = json.loads((proof_root / "receipt.json").read_text())
            default_git = [
                subprocess.CompletedProcess([], 0, runner.SOURCE_COMMIT + "\n", ""),
                subprocess.CompletedProcess([], 0, "", ""),
            ]
            receipt = expected
        (proof_root / "receipt.json").write_text(json.dumps(receipt))
        with mock.patch.multiple(
                runner,
                PATCH_SHA=runner.sha256(ROOT / "ThirdParty/BitwardenAuthSpike/identity-mfa.patch"),
                PROOF_SHA=original["artifacts"]["dylibSHA256"],
                TREE_SHA=original["artifacts"]["generatedSwiftTreeSHA256"]), \
             mock.patch.object(runner.subprocess, "run", side_effect=git_results or default_git):
            return runner.validate_receipt(proof_root, source_root)

    def test_rejects_changed_artifact_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            proof_root, source_root, receipt, git_results = self.make_valid_receipt(root)
            (proof_root / "libbitwarden_uniffi.dylib").write_bytes(b"substituted dylib")
            with mock.patch.multiple(
                    runner,
                    PATCH_SHA=runner.sha256(ROOT / "ThirdParty/BitwardenAuthSpike/identity-mfa.patch"),
                    PROOF_SHA=receipt["artifacts"]["dylibSHA256"],
                    TREE_SHA=runner.tree_sha(proof_root / "GeneratedSwift")), \
                 mock.patch.object(runner.subprocess, "run", side_effect=git_results):
                with self.assertRaises(runner.ProofError):
                    runner.validate_receipt(proof_root, source_root)

    def test_accepts_exact_receipt_fixture_with_pinned_source_seams(self):
        with tempfile.TemporaryDirectory() as temporary:
            paths = self.validate_fixture(Path(temporary))
            self.assertEqual(len(paths), 3)
            self.assertTrue(paths[0].is_file())
            self.assertTrue(paths[1].is_dir())
            self.assertTrue(paths[2].is_file())

    def test_accepts_current_reviewed_pin(self):
        runner.validate_current_pin()

    def test_rejects_revoked_or_malformed_current_pin(self):
        pin = json.loads((ROOT / "ThirdParty/BitwardenAuthSpike/pin.json").read_text())
        for overrides in ({"accepted": False}, {"accepted": 1}, {"schema": True}):
            with self.subTest(overrides=overrides), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                path = root / "ThirdParty/BitwardenAuthSpike/pin.json"
                path.parent.mkdir(parents=True)
                path.write_text(json.dumps(pin | overrides))
                with mock.patch.object(runner, "ROOT", root):
                    with self.assertRaises(runner.ProofError):
                        runner.validate_current_pin()

    def test_rejects_boolean_schema(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _, _, receipt, _ = self.make_valid_receipt(root)
            receipt["schema"] = True
            with self.assertRaises(runner.ProofError):
                self.validate_fixture(root, receipt)

    def test_rejects_malformed_nested_fields(self):
        for section, value in (("artifacts", []), ("source", None), ("host", "invalid")):
            with self.subTest(section=section), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                _, _, receipt, _ = self.make_valid_receipt(root)
                receipt[section] = value
                with self.assertRaises(runner.ProofError):
                    self.validate_fixture(root, receipt)

    def test_rejects_escaping_artifact_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _, _, receipt, _ = self.make_valid_receipt(root)
            receipt["artifacts"]["dylibPath"] = str(root / "outside.dylib")
            (root / "outside.dylib").write_bytes(b"outside")
            with self.assertRaises(runner.ProofError):
                self.validate_fixture(root, receipt)

    def test_rejects_receipt_symlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            proof_root = root / "proof"
            proof_root.mkdir()
            target = proof_root / "target.json"
            target.write_text("{}")
            (proof_root / "receipt.json").symlink_to(target)
            with self.assertRaises(runner.ProofError):
                runner.validate_receipt(proof_root, root)

    def test_sanitized_environment_drops_proxy_token_and_debug_values(self):
        safe = runner.sanitized_environment({
            "PATH": "/usr/bin", "HOME": "/tmp/home", "TMPDIR": "/tmp",
            "HTTP_PROXY": "ignored", "GH_TOKEN": "ignored", "RUST_LOG": "ignored",
            "DYLD_INSERT_LIBRARIES": "ignored", "BITWARDEN_DEBUG": "ignored",
        })
        self.assertEqual(safe, {"PATH": "/usr/bin", "HOME": "/tmp/home", "TMPDIR": "/tmp"})

    def test_expected_labels_are_exact_standalone_lines(self):
        self.assertTrue(runner.has_label("logger text\nmfa_challenge=passed\n", "mfa_challenge=passed"))
        self.assertFalse(runner.has_label("logger mfa_challenge=passed\n", "mfa_challenge=passed"))

    def test_endpoint_requires_owned_loopback_http_origin(self):
        self.assertTrue(runner.is_owned_endpoint("http://127.0.0.1:1234/"))
        for endpoint in (
            "https://127.0.0.1:1234/", "http://example.test:1234/",
            "http://user@127.0.0.1:1234/", "http://127.0.0.1:1234/?override=1",
        ):
            with self.subTest(endpoint=endpoint):
                self.assertFalse(runner.is_owned_endpoint(endpoint))

    def test_malformed_requests_are_fixed_redacted_and_listener_cleans_up(self):
        runner.FixtureHandler.state = {
            "prelogin": False, "identity": [], "mode": "normal",
            "cancel_waiting": False, "cancel_event": threading.Event(),
            "malformed_auth_seen": False, "malformed_requests_rejected": 0,
            "success_fixture": {}, "stages": {},
        }
        server = runner.FixtureServer(("127.0.0.1", 0), runner.FixtureHandler)
        server.daemon_threads = True
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        address = server.server_address
        try:
            for body in (b"secret=malformed-json", b"[]"):
                connection = http.client.HTTPConnection(*address, timeout=2)
                connection.request("POST", "/identity/accounts/prelogin/password", body,
                                   {"Content-Type": "application/json"})
                response = connection.getresponse()
                payload = response.read()
                self.assertEqual(response.status, 400)
                self.assertNotIn(b"secret", payload)
                connection.close()
            connection = http.client.HTTPConnection(*address, timeout=2)
            connection.putrequest("POST", "/identity/accounts/prelogin/password")
            connection.putheader("Content-Type", "application/json")
            connection.putheader("Content-Length", "not-a-number")
            connection.endheaders(b"secret=bad-length")
            response = connection.getresponse()
            self.assertEqual(response.status, 400)
            self.assertNotIn(b"secret", response.read())
            connection.close()
            connection = http.client.HTTPConnection(*address, timeout=2)
            connection.request("POST", "/identity/connect/token", b"\xff", {
                "Content-Type": "application/x-www-form-urlencoded",
            })
            response = connection.getresponse()
            payload = response.read()
            self.assertEqual(response.status, 400)
            self.assertEqual(payload, b"{}")
            connection.close()
            self.assertEqual(runner.FixtureHandler.state["malformed_requests_rejected"], 3)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)
        self.assertFalse(thread.is_alive())
        self.assertEqual(server.socket.fileno(), -1)
        self.assertTrue(runner.listener_is_closed(server))


if __name__ == "__main__":
    unittest.main()
