import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ArdiaCore/patches/native-password-save-offer.patch"
CANDIDATE = ROOT / "ThirdParty/ArdiaCore/patches/native-password-save-offer.candidate.json"
POLICY = ROOT / "ThirdParty/ArdiaCore/patches/native-password-policy-barrier.patch"
POLICY_CANDIDATE = ROOT / "ThirdParty/ArdiaCore/patches/native-password-policy-barrier.candidate.json"
PATCH_HASH = "287277d2ba5e3d7230c2c514bdee556994c1e6b28b71b03cb297165b188a9e6d"
CANDIDATE_HASH = "1e7a214610e2c6e48b463b88cf887cb57f2c108c71f0d819921434247fd2ac35"
POLICY_HASH = "b21b48540fc661ef73bd3a2c41123be58515b9b3b4921436122c83a0d764fef2"
POLICY_CANDIDATE_HASH = "759990c821d52951c0b1a6eee9391b02890bf60fa4434591c757e1db9f28ac5e"
CHANGED = {
    "ardia/core/ac_native_password_broker.h",
    "ardia/core/ac_native_password_broker.mm",
    "ardia/core/ac_native_password_broker_browsertest.mm",
    "ardia/core/ac_native_password_submission_state.h",
    "ardia/core/ac_native_password_submission_state_unittest.cc",
    "ardia/core/ardiacore.exports",
    "ardia/core/ardiacore_api.mm",
    "ardia/core/public/ArdiaCore.h",
    "chrome/browser/password_manager/chrome_password_manager_client.cc",
    "chrome/browser/password_manager/chrome_password_manager_client.h",
    "chrome/browser/password_manager/chrome_password_manager_client_unittest.cc",
    "components/password_manager/content/browser/content_password_manager_driver_factory.cc",
    "components/password_manager/core/browser/password_manager_client.h",
}


def digest(path):
    if any(part.is_symlink() for part in (path, *path.parents)):
        raise ValueError("symlink input")
    if not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError("input is not a regular file")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_tree(root, expected):
    if not root.is_absolute() or ".." in root.parts or any(
        part.is_symlink() for part in (root, *root.parents)
    ):
        raise ValueError("unsafe source tree")
    found = {}
    for current, directories, files in os.walk(root, followlinks=False):
        for name in directories:
            if (Path(current) / name).is_symlink():
                raise ValueError("symlink directory")
        for name in files:
            path = Path(current) / name
            found[path.relative_to(root).as_posix()] = digest(path)
    if found != expected:
        raise ValueError("source inventory mismatch")


def scratch_parent():
    path = ROOT / "build/NativePasswordSaveOfferPatchTests"
    if any(part.is_symlink() for part in (path, *path.parents)):
        raise ValueError("unsafe scratch")
    path.mkdir(parents=True, exist_ok=True)
    return path


class NativePasswordSaveOfferPatchTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for path, expected in (
            (PATCH, PATCH_HASH), (CANDIDATE, CANDIDATE_HASH),
            (POLICY, POLICY_HASH), (POLICY_CANDIDATE, POLICY_CANDIDATE_HASH),
        ):
            if digest(path) != expected:
                raise ValueError("candidate or prerequisite pin mismatch")
        cls.candidate = json.loads(CANDIDATE.read_text())
        c = cls.candidate
        if (c["schema_version"] != 1 or c["patch_sha256"] != PATCH_HASH
                or c["policy_patch_sha256"] != POLICY_HASH
                or c["policy_candidate_sha256"] != POLICY_CANDIDATE_HASH
                or c["compiled"] or c["accepted"] or c["integration_ready"]):
            raise ValueError("candidate metadata mismatch")
        before, after = c["base_source_sha256"], c["output_source_sha256"]
        if len(before) != 57 or before.keys() != after.keys():
            raise ValueError("candidate inventory mismatch")
        if {name for name in before if before[name] != after[name]} != CHANGED:
            raise ValueError("unexpected changed files")

    def test_replay_pinned_overlay(self):
        raw = os.environ.get("NATIVE_PASSWORD_SAVE_OFFER_BASE")
        if raw is None:
            self.skipTest("save-offer replay unverified: NATIVE_PASSWORD_SAVE_OFFER_BASE absent")
        base = Path(raw)
        if not raw or not base.is_absolute() or ".." in base.parts:
            raise ValueError("base must be an absolute path without traversal")
        expected = self.candidate["base_source_sha256"]
        verify_tree(base, expected)
        parent = scratch_parent()
        with tempfile.TemporaryDirectory(prefix="replay-", dir=parent) as name:
            output = Path(name)
            for relative in expected:
                target = output / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(base / relative, target)
            verify_tree(output, expected)
            env = {
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": os.environ["HOME"],
                "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_CEILING_DIRECTORIES": str(parent),
            }
            for args in (["apply", "--check", "--", str(PATCH)],
                         ["apply", "--", str(PATCH)]):
                subprocess.run(["/usr/bin/git", *args], cwd=output, env=env,
                               check=True, capture_output=True, timeout=30)
            verify_tree(output, self.candidate["output_source_sha256"])
            verify_tree(base, expected)
            for path, pin in ((PATCH, PATCH_HASH), (CANDIDATE, CANDIDATE_HASH),
                              (POLICY, POLICY_HASH), (POLICY_CANDIDATE, POLICY_CANDIDATE_HASH)):
                self.assertEqual(digest(path), pin)

    def test_tree_rejects_extra_changed_and_symlink(self):
        with tempfile.TemporaryDirectory(prefix="negative-", dir=scratch_parent()) as name:
            root = Path(name)
            item = root / "item"
            item.write_text("one")
            expected = {"item": digest(item)}
            verify_tree(root, expected)
            item.write_text("two")
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


if __name__ == "__main__":
    unittest.main()
