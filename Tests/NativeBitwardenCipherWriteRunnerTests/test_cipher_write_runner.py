"""Pure input-guard tests; never builds, launches XCTest, or opens sockets."""

import hashlib
import importlib.util
import json
import tempfile
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest import mock

RUNNER = Path(__file__).resolve().parents[2] / "scripts/test-native-bitwarden-cipher-write.py"


def load_runner():
    spec = importlib.util.spec_from_file_location("cipher_write_runner", RUNNER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / "checkout"
        self.sdk = self.base / "package"
        self.source = self.base / "sdk-source"
        self.output = self.base / "scratch"
        for directory in (self.root, self.sdk, self.source, self.output):
            directory.mkdir()
        self.m = load_runner()
        files = {}
        for n in range(83):
            name = f"files/input-{n:02d}"
            path = self.sdk / name
            path.parent.mkdir(exist_ok=True)
            path.write_text(name)
            files[name] = sha(path)
        manifest = {"accepted": False, "integration_ready": False, "testOnly": True,
                    "profile": "debug", "architecture": "arm64",
                    "sourceCommit": "5cf919837e83b71c2508bf99344ea57cf5f84e88",
                    "fileSHA256": files}
        (self.sdk / "fixture-manifest.json").write_text(json.dumps(manifest))
        for name in self.m.INPUTS:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name)
        for name in self.m.AUDIT_INPUTS:
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name)
        self.extractor = self.base / "extractor.py"
        self.extractor.write_text("# synthetic extractor\n")
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        replacements = {"ROOT": self.root, "SDK_SOURCE": self.sdk, "SOURCE": self.source,
                        "EXTRACTOR": self.extractor, "OUTPUT": self.output,
                        "HARNESS": self.output / "harness", "SDK_COPY": self.output / "SDKPackage",
                        "MANIFEST_SHA": sha(self.sdk / "fixture-manifest.json"),
                        "EXTRACTOR_SHA": sha(self.extractor),
                        "AUDIT_SHA": [sha(self.source / n) for n in self.m.AUDIT_INPUTS],
                        "FROZEN_INPUTS": {n: sha(self.root / n) for n in self.m.FROZEN_INPUTS}}
        for name, value in replacements.items():
            self.stack.enter_context(mock.patch.object(self.m, name, value, create=True))

    def test_import_has_no_execution_or_network(self):
        with mock.patch("subprocess.Popen", side_effect=AssertionError("process")), \
             mock.patch("socketserver.TCPServer.__init__", side_effect=AssertionError("socket")), \
             mock.patch("tempfile.mkdtemp", side_effect=AssertionError("scratch")):
            load_runner()

    def test_missing_and_mismatched_pinned_inputs_fail(self):
        path = self.root / self.m.INPUTS[0]
        path.unlink()
        with self.assertRaises(RuntimeError):
            self.m.input_fingerprints()
        path.write_text(self.m.INPUTS[0])
        self.extractor.write_text("changed")
        with self.assertRaisesRegex(RuntimeError, "vector"):
            self.m.input_fingerprints()

    def test_frozen_source_and_audit_drift_fail(self):
        name = next(iter(self.m.FROZEN_INPUTS))
        path = self.root / name
        original = path.read_text()
        path.write_text("changed")
        with self.assertRaisesRegex(RuntimeError, "frozen source"):
            self.m.input_fingerprints()
        path.write_text(original)
        (self.source / self.m.AUDIT_INPUTS[0]).write_text("changed")
        with self.assertRaisesRegex(RuntimeError, "vector"):
            self.m.input_fingerprints()

    def test_package_extra_missing_and_changed_fail(self):
        self.m.package_inventory(self.sdk)
        extra = self.sdk / "extra"
        extra.write_text("extra")
        with self.assertRaisesRegex(RuntimeError, "inventory"):
            self.m.package_inventory(self.sdk)
        extra.unlink()
        path = self.sdk / "files/input-00"
        original = path.read_text()
        path.unlink()
        with self.assertRaisesRegex(RuntimeError, "inventory"):
            self.m.package_inventory(self.sdk)
        path.write_text(original + "change")
        with self.assertRaisesRegex(RuntimeError, "inventory"):
            self.m.package_inventory(self.sdk)

    def test_symlink_input_and_nested_symlink_fail(self):
        path = self.root / self.m.INPUTS[0]
        path.unlink()
        path.symlink_to(self.extractor)
        with self.assertRaisesRegex(RuntimeError, "symlink"):
            self.m.input_fingerprints()
        path.unlink()
        path.write_text(self.m.INPUTS[0])
        (self.sdk / "link").symlink_to(self.extractor)
        with self.assertRaisesRegex(RuntimeError, "symlink"):
            self.m.package_inventory(self.sdk)
        (self.sdk / "link").unlink()
        link = self.base / "linked-extractor"
        link.symlink_to(self.extractor)
        with mock.patch.object(self.m, "EXTRACTOR", link):
            with self.assertRaisesRegex(RuntimeError, "symlink"):
                self.m.input_fingerprints()

    def test_staged_extra_and_drift_fail(self):
        before = self.m.input_fingerprints()
        self.m.setup()
        staged = self.m.fingerprints()
        self.assertEqual({key: staged[key] for key in before}, before)
        name = self.m.INPUTS[0]
        (self.root / name).write_text("drift")
        with self.assertRaisesRegex(RuntimeError, "harness input"):
            self.m.fingerprints()
        (self.root / name).write_text(name)
        extra = self.m.HARNESS / "Sources/extra.swift"
        extra.write_text("extra")
        with self.assertRaisesRegex(RuntimeError, "inventory"):
            self.m.fingerprints()
        extra.unlink()
        (self.m.SDK_COPY / "files/input-00").write_text("changed")
        with self.assertRaisesRegex(RuntimeError, "inventory"):
            self.m.fingerprints()

    def test_explicit_inputs_must_be_absolute(self):
        with self.assertRaises(Exception):
            self.m.absolute_argument("relative/path")
        self.assertEqual(self.m.absolute_argument("/absolute/path"), Path("/absolute/path"))


if __name__ == "__main__":
    unittest.main()
