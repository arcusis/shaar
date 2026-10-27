"""Pure checkpoint guard tests; all data lives in a private temporary directory."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/test-native-bitwarden-strict-backend.py"
spec = importlib.util.spec_from_file_location("strict_backend_runner", SCRIPT)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class StrictBackendRunnerTests(unittest.TestCase):
    def setUp(self):
        parent = runner.safe_path(SCRIPT.parents[1], "build/NativeBitwardenWriteAuthority")
        parent.mkdir(parents=True, exist_ok=True)
        runner.safe_path(SCRIPT.parents[1], "build/NativeBitwardenWriteAuthority")
        self.temp = tempfile.TemporaryDirectory(dir=parent)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.sources = self.root / "sources"
        self.sources.mkdir()
        self.files = {}
        for name in runner.INPUTS:
            path = self.sources / name
            path.parent.mkdir(parents=True, exist_ok=True)
            data = name.encode()
            path.write_bytes(data)
            self.files[name] = runner.sha(data)
        self.manifest = self.root / "checkpoint.json"

    def checkpoint(self, value=None):
        if value is None:
            value = {"schema": 1, "baseCommit": runner.ROOT_HEAD, "files": self.files}
        data = json.dumps(value).encode()
        self.manifest.write_bytes(data)
        return runner.sha(data)

    def verify(self, digest):
        return runner.verify_checkpoint(self.sources, self.manifest, digest)

    def test_valid_and_digest_mismatch(self):
        digest = self.checkpoint()
        self.assertEqual(self.verify(digest), self.files)
        with self.assertRaises(runner.GuardError):
            self.verify("0" * 64)
        (self.sources / "Package.swift").write_text("changed")
        with self.assertRaises(runner.GuardError):
            self.verify(digest)

    def test_schema_head_missing_and_extra(self):
        for change in ({"schema": True}, {"baseCommit": "0" * 40},
                       {"files": dict(list(self.files.items())[1:])},
                       {"files": {**self.files, "extra": "0" * 64}}):
            value = {"schema": 1, "baseCommit": runner.ROOT_HEAD, "files": self.files}
            value.update(change)
            with self.subTest(change=change), self.assertRaises(runner.GuardError):
                self.verify(self.checkpoint(value))

    def test_duplicate_json_unsafe_and_symlink(self):
        data = b'{"schema":1,"schema":1}'
        self.manifest.write_bytes(data)
        with self.assertRaises(runner.GuardError):
            self.verify(runner.sha(data))
        for path in ("../escape", "/absolute", "a//b", "a/./b", "a\\b"):
            with self.subTest(path=path), self.assertRaises(runner.GuardError):
                runner.safe_path(self.sources, path)
        digest = self.checkpoint()
        target = self.sources / "Package.swift"
        target.unlink()
        target.symlink_to(self.manifest)
        with self.assertRaises(runner.GuardError):
            self.verify(digest)

    def test_package_inventory_and_receipt_tampering(self):
        package = self.root / "package"
        package.mkdir()
        for index in range(84):
            (package / str(index)).write_text(str(index))
        expected = runner.inventory(package)
        value = {"accepted": False, "integrationReady": False,
                 "packages": {"debug": {"testOnly": True, "files": expected}}}
        receipt = self.root / "receipt.json"
        data = json.dumps(value).encode()
        receipt.write_bytes(data)
        with patch.object(runner, "RECEIPT_SHA256", runner.sha(data)):
            runner.verify_package(receipt, package, "debug")
            (package / "extra").write_text("extra")
            with self.assertRaises(runner.GuardError):
                runner.verify_package(receipt, package, "debug")
            (package / "extra").unlink()
            (package / "0").write_text("changed")
            with self.assertRaises(runner.GuardError):
                runner.verify_package(receipt, package, "debug")
            receipt.write_bytes(data + b" ")
            with self.assertRaises(runner.GuardError):
                runner.verify_package(receipt, package, "debug")

    def test_legacy_package_provenance_and_inventory(self):
        package = self.root / "legacy"
        package.mkdir()
        payload = package / "payload"
        payload.write_bytes(b"synthetic")
        manifest = {"schema": 1, "integration_ready": False, "accepted": True,
                    "sourceCommit": "5cf919837e83b71c2508bf99344ea57cf5f84e88",
                    "architecture": "arm64", "minMacOS": "26.0",
                    "fileSHA256": {"payload": runner.sha(b"synthetic")}}
        path = package / "build-manifest.json"
        data = json.dumps(manifest).encode()
        path.write_bytes(data)
        with patch.dict(runner.LEGACY_MANIFESTS, {"sdk3": runner.sha(data)}):
            runner.verify_legacy_package(package, "sdk3")
            with self.assertRaises(runner.GuardError):
                runner.verify_legacy_package(package, "sdk7")
            (package / "extra").write_text("extra")
            with self.assertRaises(runner.GuardError):
                runner.verify_legacy_package(package, "sdk3")
            (package / "extra").unlink()
            payload.unlink()
            payload.symlink_to(path)
            with self.assertRaises(runner.GuardError):
                runner.verify_legacy_package(package, "sdk3")

    def test_admission_extraction_rejects_missing_duplicate_and_import(self):
        block = runner.ADMISSION_BEGIN + b"struct Admission {}\n" + runner.ADMISSION_END
        with patch.object(runner, "ADMISSION_SHA256", runner.sha(block)):
            self.assertEqual(runner.admission_declaration(b"prefix\n" + block + b"suffix\n"), block)
            for source in (b"", block + block, runner.ADMISSION_END + runner.ADMISSION_BEGIN,
                           block.replace(b"Admission", b"Changed")):
                with self.subTest(source=source), self.assertRaises(runner.GuardError):
                    runner.admission_declaration(source)
        for line in (b"import AppKit\n", b"@testable import AppKit\n"):
            imported = runner.ADMISSION_BEGIN + line + runner.ADMISSION_END
            with patch.object(runner, "ADMISSION_SHA256", runner.sha(imported)):
                with self.assertRaises(runner.GuardError):
                    runner.admission_declaration(imported)

    def test_compiler_denial_requires_exact_single_error(self):
        expected = (b"AdmissionAccessProbe.swift:5:7: error: 'NativeBitwardenWriteAdmission' initializer "
                    b"is inaccessible due to 'fileprivate' protection level")
        self.assertTrue(runner.is_expected_admission_denial(expected, 1))
        annotation = b"\n | `- error: 'NativeBitwardenWriteAdmission' initializer is inaccessible due to 'fileprivate' protection level"
        self.assertTrue(runner.is_expected_admission_denial(expected + annotation, 1))
        self.assertFalse(runner.is_expected_admission_denial(expected, 0))
        self.assertFalse(runner.is_expected_admission_denial(b"error: module unavailable", 1))
        self.assertFalse(runner.is_expected_admission_denial(expected + b"\nerror: module unavailable", 1))
        self.assertFalse(runner.is_expected_admission_denial(expected + b"\nother.swift:1:2: error: unrelated", 1))
        self.assertFalse(runner.is_expected_admission_denial(expected.replace(b"AdmissionAccessProbe.swift", b"other.swift"), 1))

    def test_service_shapes_preserve_and_reject_contradictions(self):
        seed = {"name": "encrypted-name", "notes": "encrypted-note", "fields": [],
                "passwordHistory": None, "partialData": None, "data": None,
                "login": {"uris": [{"uri": "encrypted-uri", "uriChecksum": "encrypted-check", "match": 1}],
                          "username": "encrypted-user", "password": "encrypted-password", "totp": None}}
        cloud = runner.service_record(seed, "bitwarden")
        vault = runner.service_record(seed, "vaultwarden")
        self.assertEqual(cloud["permissions"], {"delete": True, "restore": True})
        self.assertNotIn("partialData", cloud)
        self.assertEqual(json.loads(cloud["data"])["Uris"][0]["Match"], 1)
        self.assertEqual(vault["login"]["uri"], vault["login"]["uris"][0]["uri"])
        self.assertNotIn("data", vault)
        self.assertNotEqual(json.loads(runner.service_record(seed, "bitwarden", "data")["data"])["Name"], seed["name"])
        self.assertEqual(runner.service_record(seed, "vaultwarden", "partial")["partialData"], "synthetic-partial")
        self.assertIsNone(seed["data"])
        with self.assertRaises(runner.GuardError):
            runner.service_record(seed, "unknown")

    def test_sdk9_profile_and_service_source_pins(self):
        package = self.root / "sdk9"
        package.mkdir()
        for index in range(84):
            (package / str(index)).write_text(str(index))
        inventory = runner.inventory(package)
        value = {"accepted": False, "integrationReady": False,
                 "packages": {"debug": {"testOnly": True, "files": inventory,
                                        "manifestSHA256": runner.SDK9_MANIFESTS["debug"]}}}
        data = json.dumps(value).encode()
        receipt = self.root / "sdk9-receipt.json"
        receipt.write_bytes(data)
        with patch.object(runner, "SDK9_RECEIPT_SHA256", runner.sha(data)):
            runner.verify_package(receipt, package, "debug", "sdk9")
            with self.assertRaises(runner.GuardError):
                runner.verify_package(receipt, package, "debug", "sdk8")
            (package / "0").write_text("tampered")
            with self.assertRaises(runner.GuardError):
                runner.verify_package(receipt, package, "debug", "sdk9")
        primary = self.root / "primary"
        primary.mkdir()
        source = primary / "model"
        source.write_bytes(b"model")
        candidate = self.root / "candidate"
        candidate_data = json.dumps({"primarySha256": {"model": runner.sha(b"model")},
                                     "patchSha256": runner.sha(b"patch"),
                                     "sourceCommit": "5cf919837e83b71c2508bf99344ea57cf5f84e88"}).encode()
        candidate.write_bytes(candidate_data)
        source_patch = self.root / "patch"
        source_patch.write_bytes(b"patch")
        with patch.object(runner, "SERVICE_PRIMARY", {"model": runner.sha(b"model")}), \
             patch.object(runner, "SERVICE_CANDIDATE_SHA256", runner.sha(candidate_data)), \
             patch.object(runner, "SERVICE_PATCH_SHA256", runner.sha(b"patch")):
            runner.verify_service_sources(primary, candidate, source_patch)
            source.write_bytes(b"changed")
            with self.assertRaises(runner.GuardError):
                runner.verify_service_sources(primary, candidate, source_patch)


if __name__ == "__main__":
    unittest.main()
