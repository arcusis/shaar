from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
COMMIT = "5cf919837e83b71c2508bf99344ea57cf5f84e88"
TREE = "9af9432aefeed6796e40e5019ffdc8600f3381e9"
FIVE_TREE = "11ed604aabfcee88eac5c4ce2b486f9628796914"
SIX_TREE = "64151eb07bdbe0bba1b48aeeea6a8b1add2c4ac9"
LAYERS = {
    "ThirdParty/BitwardenAuthSpike/identity-mfa.patch": "850c53c73c710772b338bc88760543f66562119984e25bcf0337bfa986842a91",
    "ThirdParty/BitwardenKeyClearSpike/clear-crypto-keys.patch": "f62fb617c615570d1a4280fd459af8b081caa758ad50fe4f57ebd7b34bdc2bf4",
    "ThirdParty/BitwardenSyncSpike/sync.patch": "26c6c57921ade94d4b6bed4b1627bf879ee6665fe23b5462b4b10a79633c7533",
    "ThirdParty/BitwardenSyncSpike/organization-keys.patch": "b61303ecba50f6b1e75a083324e231878ae80d5663593302fede22dbd785cf1d",
    "ThirdParty/BitwardenSyncSpike/organization-key-replacement.patch": "4079044d3bd8dd3e8427ec86a1b2901704e4a08d2491dd67dbbf06dd2778294b",
}
PATCH_HASH = "dbbade935ba424c56bbbe788ff87403c8404af1bd733a1e9a0175f34b836b6e8"
PATCH = "ThirdParty/BitwardenRefreshSpike/refresh.patch"
PIN = ROOT / "ThirdParty/BitwardenRefreshSpike/refresh.candidate.json"
FILES = [
    "crates/bitwarden-core/src/auth/api/request/mod.rs",
    "crates/bitwarden-core/src/auth/api/request/renew_token_request.rs",
    "crates/bitwarden-core/src/auth/renew.rs",
    "crates/bitwarden-pm/src/lib.rs",
    "crates/bitwarden-uniffi/src/auth/mod.rs",
    "crates/bitwarden-uniffi/src/sync.rs",
]
ENV = {"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": os.environ["HOME"], "TMPDIR": os.environ["TMPDIR"]}


def run(*args: str, cwd: Path | None = None) -> str:
    return subprocess.run(args, cwd=cwd, env=ENV, check=True, text=True, capture_output=True).stdout.strip()


def validate(pin: dict, patch: bytes, layers: dict[str, bytes]) -> None:
    expected = {
        "schema": 1, "accepted": False, "compiled": False, "integration_ready": False,
        "repository": "https://github.com/bitwarden/sdk-internal", "sourceCommit": COMMIT,
        "sourceTree": TREE, "fiveLayerTree": FIVE_TREE, "sixLayerTree": SIX_TREE, "prerequisites": [{"file": p, "sha256": h} for p, h in LAYERS.items()],
        "patchFile": PATCH, "changedFiles": FILES,
    }
    if type(pin) is not dict or set(pin) != set(expected) | {"patchSHA256", "patchBytes"}:
        raise ValueError("invalid pin shape")
    for key, value in expected.items():
        if type(pin[key]) is not type(value) or pin[key] != value:
            raise ValueError("invalid " + key)
    if type(pin["patchBytes"]) is not int or pin["patchBytes"] != len(patch) or pin["patchSHA256"] != PATCH_HASH or hashlib.sha256(patch).hexdigest() != PATCH_HASH:
        raise ValueError("invalid patch digest or size")
    if set(layers) != set(LAYERS) or any(hashlib.sha256(layers[p]).hexdigest() != h for p, h in LAYERS.items()):
        raise ValueError("invalid prerequisite")
    paths = [line.split("\t")[2] for line in run("git", "apply", "--numstat", str(ROOT / PATCH), cwd=ROOT).splitlines()]
    if paths != FILES:
        raise ValueError("invalid patch scope")


def snapshot(root: Path) -> dict[str, str]:
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in root.rglob("*") if p.is_file() and ".git" not in p.relative_to(root).parts}


class RefreshPatchTests(unittest.TestCase):
    def setUp(self):
        self.pin = json.loads(PIN.read_text())
        self.patch = (ROOT / PATCH).read_bytes()
        self.layers = {p: (ROOT / p).read_bytes() for p in LAYERS}

    def test_pin_and_tampering(self):
        validate(self.pin, self.patch, self.layers)
        for key, value in [("accepted", True), ("compiled", True), ("integration_ready", True),
                           ("sourceCommit", "0" * 40), ("sourceTree", "0" * 40),
                           ("patchBytes", True), ("changedFiles", []),
                           ("prerequisites", list(reversed(self.pin["prerequisites"])) )]:
            altered = copy.deepcopy(self.pin)
            altered[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate(altered, self.patch, self.layers)
        with self.assertRaises(ValueError):
            validate(self.pin, self.patch + b"tamper", self.layers)
        altered = copy.deepcopy(self.pin)
        tampered = self.patch + b"tamper"
        altered["patchBytes"] = len(tampered)
        altered["patchSHA256"] = hashlib.sha256(tampered).hexdigest()
        with self.assertRaises(ValueError):
            validate(altered, tampered, self.layers)
        layers = dict(self.layers)
        layers[next(iter(layers))] += b"tamper"
        with self.assertRaises(ValueError):
            validate(self.pin, self.patch, layers)

    def test_prerequisite_pin_manifests(self):
        manifests = [
            "ThirdParty/BitwardenAuthSpike/pin.json",
            "ThirdParty/BitwardenKeyClearSpike/pin.json",
            "ThirdParty/BitwardenSyncSpike/pin.json",
            "ThirdParty/BitwardenSyncSpike/organization-keys.pin.json",
            "ThirdParty/BitwardenSyncSpike/organization-key-replacement.pin.json",
        ]
        for manifest, (path, digest) in zip(manifests, LAYERS.items(), strict=True):
            pin = json.loads((ROOT / manifest).read_text())
            self.assertEqual(pin["sourceCommit"], COMMIT)
            self.assertEqual(pin["repository"], "https://github.com/bitwarden/sdk-internal")
            self.assertEqual(pin["patchSHA256"], digest)
            self.assertEqual(pin["patchBytes"], len(self.layers[path]))
            if "sourceTree" in pin:
                self.assertEqual(pin["sourceTree"], TREE)
            if "sourceTreeSHA256" in pin:
                self.assertEqual(pin["sourceTreeSHA256"], TREE)

    def test_six_layers_apply_to_exact_git_objects(self):
        validate(self.pin, self.patch, self.layers)
        source = Path(os.environ.get("BITWARDEN_REFRESH_SOURCE", str(ROOT / "build/SDKCache/bitwarden-sdk-5cf9198")))
        if not source.exists() and "BITWARDEN_REFRESH_SOURCE" not in os.environ:
            self.skipTest("pinned source Git objects unavailable")
        self.assertEqual(run("git", "rev-parse", COMMIT + "^{commit}", cwd=source), COMMIT)
        self.assertEqual(run("git", "rev-parse", COMMIT + "^{tree}", cwd=source), TREE)
        work = ROOT / "build/NativeRefreshSDK"
        work.mkdir(parents=True, exist_ok=True)
        tmp = Path(tempfile.mkdtemp(prefix="six-layer-", dir=work))
        archive = tmp / "source.tar"
        with archive.open("wb") as out:
            subprocess.run(["git", "archive", COMMIT], cwd=source, env=ENV, stdout=out, check=True)
        dest = tmp / "sdk"
        dest.mkdir()
        with tarfile.open(archive) as tar:
            tar.extractall(dest, filter="data")
        run("git", "init", "-q", cwd=dest)
        for layer in [*LAYERS, PATCH]:
            before = snapshot(dest)
            expected = [line.split("\t")[2] for line in run("git", "apply", "--numstat", str(ROOT / layer), cwd=dest).splitlines()]
            run("git", "apply", "--check", str(ROOT / layer), cwd=dest)
            run("git", "apply", str(ROOT / layer), cwd=dest)
            after = snapshot(dest)
            changed = sorted(p for p in before.keys() | after.keys() if before.get(p) != after.get(p))
            self.assertEqual(changed, sorted(expected), layer)
            if layer in (list(LAYERS)[-1], PATCH):
                run("git", "add", "-A", cwd=dest)
                self.assertEqual(run("git", "write-tree", cwd=dest), SIX_TREE if layer == PATCH else FIVE_TREE)
            if layer == PATCH:
                self.assertEqual(changed, sorted(FILES))


if __name__ == "__main__":
    unittest.main()
