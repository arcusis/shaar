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
        parent = runner.safe_path(SCRIPT.parents[1], "build/NativeBitwardenStrictBackend")
        parent.mkdir(parents=True, exist_ok=True)
        runner.safe_path(SCRIPT.parents[1], "build/NativeBitwardenStrictBackend")
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


if __name__ == "__main__":
    unittest.main()
