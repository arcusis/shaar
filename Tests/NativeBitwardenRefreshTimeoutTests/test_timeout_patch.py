from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CANDIDATE = ROOT / "ThirdParty/BitwardenRefreshSpike/deadline.candidate.json"
PATCH = ROOT / "ThirdParty/BitwardenRefreshSpike/native-http-deadline.patch"
SOURCE = ROOT / "build/SDKCache/bitwarden-sdk-5cf9198"
spec = importlib.util.spec_from_file_location("sdk_builder", ROOT / "scripts/build-native-bitwarden-sdk.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)
ENV = {key: os.environ[key] for key in ("PATH", "HOME", "TMPDIR")}


def run(*args, cwd=None):
    return subprocess.run(args, cwd=cwd, env=ENV, check=True, capture_output=True, text=True).stdout.strip()


def validate(candidate, patch):
    if hashlib.sha256(patch).hexdigest() != "8ec29eb0694c0624788922950b878d05e324dc344fbcfb5d44f34f307b862b87":
        raise ValueError("patch digest")
    expected = {
        "schema": 1, "accepted": False, "compiled": False, "integration_ready": False,
        "sourceCommit": "5cf919837e83b71c2508bf99344ea57cf5f84e88",
        "sourceGitTree": "9af9432aefeed6796e40e5019ffdc8600f3381e9",
        "sixLayerTree": "64151eb07bdbe0bba1b48aeeea6a8b1add2c4ac9",
        "sevenLayerTree": "0a934e609b3dfef012a3477d2973ace834b1a1c2",
        "patchFile": "ThirdParty/BitwardenRefreshSpike/native-http-deadline.patch",
        "patchSHA256": "8ec29eb0694c0624788922950b878d05e324dc344fbcfb5d44f34f307b862b87",
        "patchBytes": len(patch),
        "changedFiles": ["crates/bitwarden-api-base/src/client.rs"],
        "sourceManifestSHA256": "a07d87fa57dc49dd53fadc2924c2ad4b9764ae61a708a872b7e8b16bf625ec79",
        "sourceManifestEntries": 2356,
        "fullDiffSHA256": "2dd1ac8411b2285ca214345161d6865d46dee1b868bc8f82bf49716d02ff4588",
        "candidateCargoLockSHA256": "a0bfda50537e4bbf11bbd68fce2250ca6c2fdbf80538b3ec953d746c607a88a3",
        "nativeConnectTimeoutSeconds": 10, "nativeTotalTimeoutSeconds": 30,
        "changedPaths": sorted(set(builder.read_refresh_pin()["changedPaths"]) |
                               {"crates/bitwarden-api-base/src/client.rs"}),
    }
    if type(candidate) is not dict or set(candidate) != set(expected):
        raise ValueError("candidate shape")
    for key, value in expected.items():
        if type(candidate[key]) is not type(value) or candidate[key] != value:
            raise ValueError("candidate mismatch: " + key)


class DeadlinePatchTests(unittest.TestCase):
    def test_candidate_and_tampering(self):
        candidate = json.loads(CANDIDATE.read_text()); patch = PATCH.read_bytes()
        validate(candidate, patch)
        for key, bad in [("accepted", True), ("compiled", True), ("integration_ready", True),
                         ("nativeConnectTimeoutSeconds", 9), ("nativeTotalTimeoutSeconds", 0),
                         ("sevenLayerTree", "0" * 40), ("changedFiles", []), ("schema", True)]:
            changed = copy.deepcopy(candidate); changed[key] = bad
            with self.subTest(key=key), self.assertRaises(ValueError): validate(changed, patch)
        with self.assertRaises(ValueError): validate(candidate, patch + b"tamper")
        pin = builder.read_bounded_pin()
        self.assertEqual(pin["candidateGitTree"], candidate["sevenLayerTree"])
        self.assertEqual(pin["generatedSHA256"], builder.read_refresh_pin()["generatedSHA256"])

    def test_reconstructs_seven_layers_from_pinned_git_objects(self):
        candidate = json.loads(CANDIDATE.read_text()); validate(candidate, PATCH.read_bytes())
        if not SOURCE.is_dir():
            self.skipTest("pinned SDK Git objects unavailable; reconstruction not verified")
        self.assertEqual(run("git", "-C", str(SOURCE), "rev-parse", candidate["sourceCommit"] + "^{tree}"), candidate["sourceGitTree"])
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); archive = root / "base.tar"; sdk = root / "sdk"; sdk.mkdir()
            with archive.open("wb") as stream:
                subprocess.run(["git", "-C", str(SOURCE), "archive", candidate["sourceCommit"]], env=ENV, stdout=stream, check=True)
            with tarfile.open(archive) as tar: tar.extractall(sdk, filter="data")
            run("git", "init", "-q", cwd=sdk)
            for patch_name in builder.BOUNDED_PATCH_ORDER:
                run("git", "apply", "--check", "--whitespace=error", str(ROOT / patch_name), cwd=sdk)
                run("git", "apply", "--whitespace=error", str(ROOT / patch_name), cwd=sdk)
                if patch_name in (builder.REFRESH_PATCH_ORDER[-1], builder.BOUNDED_PATCH_ORDER[-1]):
                    run("git", "add", "-A", cwd=sdk)
                    tree = run("git", "write-tree", cwd=sdk)
                    self.assertEqual(tree, candidate["sevenLayerTree"] if patch_name == builder.BOUNDED_PATCH_ORDER[-1] else candidate["sixLayerTree"])
            self.assertEqual(builder.source_manifest(sdk), (candidate["sourceManifestSHA256"], candidate["sourceManifestEntries"]))
            self.assertEqual(builder.digest(sdk / "Cargo.lock"), candidate["candidateCargoLockSHA256"])
            code = (sdk / candidate["changedFiles"][0]).read_text()
            self.assertEqual(code.count(".connect_timeout(Duration::from_secs(10))"), 1)
            self.assertEqual(code.count(".timeout(Duration::from_secs(30))"), 1)
            native = code.index('#[cfg(not(target_arch = "wasm32"))]')
            self.assertLess(native, code.index(".connect_timeout(Duration::from_secs(10))"))
            self.assertLess(code.index(".timeout(Duration::from_secs(30))"), code.index(".https_only(true)"))


if __name__ == "__main__":
    unittest.main()
