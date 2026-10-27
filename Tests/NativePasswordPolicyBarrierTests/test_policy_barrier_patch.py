import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ArdiaCore/patches/native-password-policy-barrier.patch"
CANDIDATE = ROOT / "ThirdParty/ArdiaCore/patches/native-password-policy-barrier.candidate.json"
CANDIDATE_SHA256 = "759990c821d52951c0b1a6eee9391b02890bf60fa4434591c757e1db9f28ac5e"
PATCH_SHA256 = "b21b48540fc661ef73bd3a2c41123be58515b9b3b4921436122c83a0d764fef2"
SUBMISSION_SHA256 = "7e98a253bf45df3c51e2f0b4b1d4a709367227d82c2179655a5862d4187f8c68"
SUBMISSION_MANIFEST_SHA256 = "6058c0146282679ffc0e3f533920a17d088f277b65d511fbfed781eeaecf6ba8"
PROFILE_SHA256 = "be7185ea26fa81164c2407f9055a260f96c1f0aafffa204878e16cf984758545"
WINDOW_SHA256 = "5686f1a15aefadf3a57a718410ae4a8b2683d0dabe55fd0bdc5ac11b6edf8a3b"
REPLAY_INPUTS = (
    "NATIVE_PASSWORD_POLICY_BASE",
    "NATIVE_PASSWORD_SUBMISSION_PATCH",
    "NATIVE_PASSWORD_SUBMISSION_MANIFEST",
    "NATIVE_PASSWORD_PROVIDER_PATCH",
    "NATIVE_PASSWORD_DOCUMENT_URL_PATCH",
    "NATIVE_PASSWORD_PROFILE_PATCH",
    "NATIVE_PASSWORD_WINDOW_PATCH",
)


def replay_inputs(environment):
    supplied = [name for name in REPLAY_INPUTS if name in environment]
    if not supplied:
        return None
    missing = [name for name in REPLAY_INPUTS if name not in environment]
    if missing:
        raise ValueError("incomplete replay inputs; missing " + ", ".join(missing))
    paths = []
    for name in REPLAY_INPUTS:
        raw = environment[name]
        path = Path(raw)
        if not raw or not path.is_absolute() or ".." in path.parts:
            raise ValueError(f"{name} must be a nonempty absolute path without traversal")
        if any(part.is_symlink() for part in (path, *path.parents)):
            raise ValueError(f"{name} has a symlink")
        paths.append(path)
    return paths


def scratch_parent():
    path = ROOT / "build/NativePasswordPolicyBarrierTests"
    if any(part.is_symlink() for part in (path, *path.parents)):
        raise ValueError("scratch path has a symlink")
    path.mkdir(parents=True, exist_ok=True)
    if any(part.is_symlink() for part in (path, *path.parents)):
        raise ValueError("scratch path has a symlink")
    return path


def file_hash(path):
    if any(part.is_symlink() for part in (path, *path.parents)):
        raise ValueError("file path has a symlink")
    if not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError("file is not regular")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_tree(root, expected):
    if not root.is_absolute() or any(part.is_symlink() for part in (root, *root.parents)):
        raise ValueError("tree path must be absolute without symlink ancestors")
    found = {}
    for current, directories, files in os.walk(root, followlinks=False):
        directory = Path(current)
        for name in directories:
            if (directory / name).is_symlink():
                raise ValueError("symlink directory")
        for name in files:
            path = directory / name
            if not stat.S_ISREG(path.lstat().st_mode):
                raise ValueError("non-regular file")
            found[path.relative_to(root).as_posix()] = file_hash(path)
    if found != expected:
        raise ValueError("inventory or content mismatch")


class NativePasswordPolicyBarrierPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if file_hash(CANDIDATE) != CANDIDATE_SHA256 or file_hash(PATCH) != PATCH_SHA256:
            raise ValueError("candidate or patch hash mismatch")
        cls.candidate = json.loads(CANDIDATE.read_text())
        if cls.candidate["schema_version"] != 1 or len(cls.candidate["base_source_sha256"]) != 54:
            raise ValueError("unexpected candidate schema or base inventory")
        if cls.candidate["patch_sha256"] != PATCH_SHA256:
            raise ValueError("patch pin mismatch")
        if cls.candidate["compiled"] or cls.candidate["accepted"] or cls.candidate["integration_ready"]:
            raise ValueError("unexpected acceptance state")

    def test_replay_pinned_overlay(self):
        inputs = replay_inputs(os.environ)
        if inputs is None:
            self.skipTest("pinned source replay unverified: all seven NATIVE_PASSWORD_* inputs absent")
        base, prerequisite, prerequisite_manifest, provider, document_url, profile, window = inputs
        assembled = self.candidate["additional_assembled_prerequisite_sha256"]
        pinned_inputs = (
            (prerequisite, SUBMISSION_SHA256),
            (prerequisite_manifest, SUBMISSION_MANIFEST_SHA256),
            (provider, assembled["native-password-provider.patch"]),
            (document_url, assembled["native-password-document-url.patch"]),
            (profile, PROFILE_SHA256),
            (window, WINDOW_SHA256),
        )
        for path, expected_hash in pinned_inputs:
            self.assertEqual(file_hash(path), expected_hash)
        expected_base = self.candidate["base_source_sha256"]
        expected_output = dict(expected_base)
        expected_output.update(self.candidate["changed_source_sha256"])
        verify_tree(base, expected_base)
        output_parent = scratch_parent()
        with tempfile.TemporaryDirectory(prefix="replay-", dir=output_parent) as name:
            output = Path(name).resolve()
            for rel in expected_base:
                source = base / rel
                target = output / rel
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
            verify_tree(output, expected_base)
            env = {
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": os.environ["HOME"],
                "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_CEILING_DIRECTORIES": str(output_parent),
            }
            for args in (["apply", "--check", "--", str(PATCH)],
                         ["apply", "--", str(PATCH)]):
                subprocess.run(["/usr/bin/git", *args], cwd=output, env=env,
                               check=True, capture_output=True, text=True, timeout=30)
            verify_tree(output, expected_output)
            mojom = (output / "components/autofill/content/common/mojom/autofill_agent.mojom").read_text()
            self.assertIn("struct NativeFocusedFormSnapshot", mojom)
            self.assertLess(mojom.index("FillNativePasswordSuggestion("),
                            mojom.index("InstallNativePasswordLogSuppression()"))
            driver = (output / "components/password_manager/content/browser/content_password_manager_driver.cc").read_text()
            self.assertEqual(driver.count('#include "mojo/public/cpp/bindings/callback_helpers.h"'), 1)
            self.assertIn("ContentPasswordManagerDriver::GetNativeFocusedFormSnapshot", driver)
            self.assertIn("ContentPasswordManagerDriver::FillNativePasswordSuggestion", driver)
            broker = (output / "ardia/core/ac_native_password_broker.mm").read_text()
            self.assertIn('#include "content/public/browser/ssl_status.h"', broker)
            self.assertIn("base::WeakPtr<password_manager::PasswordManagerDriver>()", broker)
            verify_tree(base, expected_base)
            for path, expected_hash in pinned_inputs:
                self.assertEqual(file_hash(path), expected_hash)
            self.assertEqual(file_hash(PATCH), PATCH_SHA256)
            self.assertEqual(file_hash(CANDIDATE), CANDIDATE_SHA256)

    def test_tree_guard_rejects_drift_extra_and_symlink(self):
        output_parent = scratch_parent()
        with tempfile.TemporaryDirectory(prefix="negative-", dir=output_parent) as name:
            root = Path(name).resolve()
            item = root / "one"
            item.write_text("one")
            expected = {"one": file_hash(item)}
            verify_tree(root, expected)
            item.write_text("changed")
            with self.assertRaises(ValueError):
                verify_tree(root, expected)
            item.write_text("one")
            (root / "extra").write_text("extra")
            with self.assertRaises(ValueError):
                verify_tree(root, expected)
            (root / "extra").unlink()
            item.unlink()
            item.symlink_to("missing")
            with self.assertRaises(ValueError):
                verify_tree(root, expected)

    def test_replay_selection_absent_partial_and_invalid(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(unittest.SkipTest, "replay unverified"):
                self.test_replay_pinned_overlay()
        with mock.patch.dict(os.environ, {REPLAY_INPUTS[0]: "/unused"}, clear=True):
            with self.assertRaisesRegex(ValueError, "incomplete replay inputs"):
                self.test_replay_pinned_overlay()
        all_inputs = dict.fromkeys(REPLAY_INPUTS, "/missing-native-policy-input")
        with mock.patch.dict(os.environ, all_inputs, clear=True):
            with self.assertRaises(FileNotFoundError):
                self.test_replay_pinned_overlay()
        all_inputs[REPLAY_INPUTS[-1]] = "relative"
        with mock.patch.dict(os.environ, all_inputs, clear=True):
            with self.assertRaisesRegex(ValueError, "absolute path"):
                self.test_replay_pinned_overlay()

    def test_replay_rejects_symlink_input(self):
        with tempfile.TemporaryDirectory(prefix="unsafe-", dir=scratch_parent()) as name:
            link = Path(name) / "link"
            link.symlink_to(Path(name) / "missing")
            inputs = dict.fromkeys(REPLAY_INPUTS, "/missing-native-policy-input")
            inputs[REPLAY_INPUTS[0]] = str(link)
            with mock.patch.dict(os.environ, inputs, clear=True):
                with self.assertRaisesRegex(ValueError, "symlink"):
                    self.test_replay_pinned_overlay()


if __name__ == "__main__":
    unittest.main()
