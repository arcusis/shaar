import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

RUNNER = Path(__file__).resolve().parents[2] / "scripts/test-native-bitwarden-process-restart.py"
spec = importlib.util.spec_from_file_location("restart_runner", RUNNER)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class SourceCheckpointTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.manifest = self.root / "build/Verification/checkpoint.json"
        self.manifest.parent.mkdir(parents=True)
        self.paths = ["Package.swift", "Sources/A.swift", "Tests/A.swift", *runner.SOURCE_SCRIPTS]
        for name in self.paths:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name)
        self.head = "a" * 40
        self.data = {"schema": 1, "sourceCommit": self.head, "files": {
            name: hashlib.sha256((self.root / name).read_bytes()).hexdigest() for name in self.paths
        }}
        self.git = patch.object(runner.subprocess, "run")
        self.mock_git = self.git.start()
        self.addCleanup(self.git.stop)
        self.mock_git.return_value.stdout = self.head + "\n"

    def write(self, raw=None):
        self.manifest.write_text(json.dumps(self.data) if raw is None else raw)
        return hashlib.sha256(self.manifest.read_bytes()).hexdigest()

    def validate(self, digest=None, path=None):
        return runner.validate_source_manifest(
            self.root, path or self.manifest, digest or self.write())

    def test_valid_checkpoint_checks_complete_inventory(self):
        self.assertEqual(self.validate(), self.data["files"])

    def test_manifest_digest_mismatch_fails(self):
        self.write()
        with self.assertRaisesRegex(RuntimeError, "manifest digest mismatch"):
            self.validate("0" * 64)

    def test_source_payload_mismatch_fails(self):
        (self.root / "Sources/A.swift").write_text("changed")
        with self.assertRaisesRegex(RuntimeError, "payload mismatch"):
            self.validate()

    def test_head_mismatch_fails(self):
        self.mock_git.return_value.stdout = "b" * 40 + "\n"
        with self.assertRaisesRegex(RuntimeError, "HEAD mismatch"):
            self.validate()

    def test_missing_manifest_path_fails(self):
        del self.data["files"]["Sources/A.swift"]
        with self.assertRaisesRegex(RuntimeError, "inventory mismatch"):
            self.validate()

    def test_extra_manifest_path_fails(self):
        self.data["files"]["Sources/extra.swift"] = "0" * 64
        with self.assertRaisesRegex(RuntimeError, "inventory mismatch"):
            self.validate()

    def test_unlisted_actual_file_fails(self):
        (self.root / "Tests/extra.swift").write_text("extra")
        with self.assertRaisesRegex(RuntimeError, "inventory mismatch"):
            self.validate()

    def test_duplicate_json_key_fails(self):
        raw = json.dumps(self.data).replace('"schema": 1', '"schema": 1, "schema": 1')
        expected = self.write(raw)
        with self.assertRaisesRegex(RuntimeError, "duplicate manifest key"):
            self.validate(expected)

    def test_malformed_schema_and_hash_fail(self):
        for value in (True, 2, "1"):
            with self.subTest(value=value):
                self.data["schema"] = value
                with self.assertRaisesRegex(RuntimeError, "invalid source manifest"):
                    self.validate()
        self.data["schema"] = 1
        self.data["files"]["Sources/A.swift"] = "bogus"
        with self.assertRaisesRegex(RuntimeError, "invalid source hash"):
            self.validate()

    def test_malformed_json_fails(self):
        expected = self.write("{")
        with self.assertRaises(json.JSONDecodeError):
            self.validate(expected)

    def test_unsafe_source_path_fails(self):
        for name in ("../escape", "/absolute", "Sources/../A.swift", "Sources//A.swift", "Sources/./A.swift", "Sources\\A.swift"):
            with self.subTest(name=name), self.assertRaises(RuntimeError):
                runner.safe_file(self.root, name)

    def test_symlink_source_and_directory_fail(self):
        path = self.root / "Sources/A.swift"
        path.unlink()
        path.symlink_to(self.root / "Package.swift")
        with self.assertRaisesRegex(RuntimeError, "unsafe source file"):
            self.validate()
        path.unlink()
        (self.root / "Sources/link").symlink_to(self.root / "Tests", target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, "unsafe source directory"):
            self.validate()

    def test_special_source_file_fails(self):
        os.mkfifo(self.root / "Sources/fifo")
        with self.assertRaisesRegex(RuntimeError, "unsafe source file"):
            self.validate()

    def test_manifest_path_must_be_canonical_and_inside_verification(self):
        expected = self.write()
        outside = self.root / "outside.json"
        outside.write_bytes(self.manifest.read_bytes())
        for path in (outside, self.manifest.parent / "alias.json"):
            if path.name == "alias.json":
                path.symlink_to(self.manifest)
            with self.subTest(path=path), self.assertRaises(RuntimeError):
                self.validate(expected, path)


class PackageCheckpointTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.manifest = self.root / "fixture-manifest.json"
        self.inventory = {}
        for number in range(83):
            name = f"payload-{number}"
            path = self.root / name
            path.write_text(name)
            self.inventory[name] = hashlib.sha256(path.read_bytes()).hexdigest()
        self.data = {"accepted": False, "integration_ready": False, "architecture": "arm64",
                     "minMacOS": "26.0", "sourceCommit": "5cf919837e83b71c2508bf99344ea57cf5f84e88",
                     "testOnly": True, "profile": "debug", "fileSHA256": self.inventory}
        self.manifest.write_text(json.dumps(self.data))
        self.expected = hashlib.sha256(self.manifest.read_bytes()).hexdigest()
        self.base = patch.object(runner, "base", SimpleNamespace(digest=runner.digest))
        self.base.start()
        self.addCleanup(self.base.stop)

    def test_package_payload_and_manifest_pinned(self):
        runner.validate_package(self.root, self.manifest.name, self.expected, True)
        (self.root / "payload-0").write_text("changed")
        with self.assertRaisesRegex(RuntimeError, "package payload changed"):
            runner.validate_package(self.root, self.manifest.name, self.expected, True)
        with self.assertRaisesRegex(RuntimeError, "package manifest mismatch"):
            runner.validate_package(self.root, self.manifest.name, "0" * 64, True)

    def test_package_rejects_extra_and_symlink(self):
        (self.root / "extra").write_text("extra")
        with self.assertRaisesRegex(RuntimeError, "package inventory changed"):
            runner.validate_package(self.root, self.manifest.name, self.expected, True)
        (self.root / "extra").unlink()
        (self.root / "linked").symlink_to(self.root / "payload-0")
        with self.assertRaisesRegex(RuntimeError, "package symlink rejected"):
            runner.validate_package(self.root, self.manifest.name, self.expected, True)


if __name__ == "__main__":
    unittest.main()
