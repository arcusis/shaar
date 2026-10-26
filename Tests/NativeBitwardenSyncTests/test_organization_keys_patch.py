from __future__ import annotations

import copy
import hashlib
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PIN = ROOT / "ThirdParty/BitwardenSyncSpike/organization-keys.pin.json"
COMMIT = "5cf919837e83b71c2508bf99344ea57cf5f84e88"
TREE = "9af9432aefeed6796e40e5019ffdc8600f3381e9"
PATCH = "ThirdParty/BitwardenSyncSpike/organization-keys.patch"
LAYERS = {
    "ThirdParty/BitwardenAuthSpike/identity-mfa.patch": "850c53c73c710772b338bc88760543f66562119984e25bcf0337bfa986842a91",
    "ThirdParty/BitwardenKeyClearSpike/clear-crypto-keys.patch": "f62fb617c615570d1a4280fd459af8b081caa758ad50fe4f57ebd7b34bdc2bf4",
    "ThirdParty/BitwardenSyncSpike/sync.patch": "26c6c57921ade94d4b6bed4b1627bf879ee6665fe23b5462b4b10a79633c7533",
}
FILES = ["Cargo.lock", "crates/bitwarden-pm/Cargo.toml", "crates/bitwarden-pm/src/lib.rs", "crates/bitwarden-uniffi/src/sync.rs"]


def run(*args: str, cwd: Path | None = None) -> str:
    return subprocess.run(args, cwd=cwd, check=True, text=True, capture_output=True).stdout.strip()


def validate_pin(pin: dict) -> None:
    """Validate metadata against fixed scope before resolving any paths."""
    if not isinstance(pin, dict):
        raise ValueError("pin must be an object")
    expected = {
        "schema": 1, "accepted": False, "integration_ready": False,
        "repository": "https://github.com/bitwarden/sdk-internal",
        "sourceCommit": COMMIT, "sourceTree": TREE, "patchFile": PATCH,
        "changedFiles": FILES, "rustToolchain": "1.90-aarch64-apple-darwin",
        "target": "aarch64-apple-darwin",
        "prerequisites": [{"file": path, "sha256": digest} for path, digest in LAYERS.items()],
    }
    if set(pin) != set(expected) | {"patchSHA256", "patchBytes"}:
        raise ValueError("unexpected pin fields")
    for key, value in expected.items():
        if type(pin[key]) is not type(value) or pin[key] != value:
            raise ValueError(f"invalid {key}")
    payload = (ROOT / PATCH).read_bytes()
    if type(pin["patchBytes"]) is not int or pin["patchBytes"] != len(payload):
        raise ValueError("invalid patchBytes")
    if pin["patchSHA256"] != hashlib.sha256(payload).hexdigest():
        raise ValueError("invalid patchSHA256")
    for path, digest in LAYERS.items():
        if hashlib.sha256((ROOT / path).read_bytes()).hexdigest() != digest:
            raise ValueError(f"invalid layer hash: {path}")
    lines = run("git", "apply", "--numstat", str(ROOT / PATCH)).splitlines()
    paths = [line.split("\t")[2] for line in lines]
    if sorted(paths) != sorted(FILES):
        raise ValueError("invalid patch scope")


class OrganizationKeysPatchTests(unittest.TestCase):
    def setUp(self):
        self.pin = json.loads(PIN.read_text())

    def test_portable_pin_hashes_and_scope(self):
        validate_pin(self.pin)

    def test_rejects_malformed_metadata(self):
        mutations = [
            ("schema", True), ("accepted", 0), ("integration_ready", True),
            ("sourceCommit", "0" * 40), ("sourceTree", "0" * 40),
            ("patchFile", "../../outside"), ("patchSHA256", "0" * 64),
            ("patchBytes", True), ("changedFiles", FILES + ["outside"]),
            ("prerequisites", list(reversed(self.pin["prerequisites"]))),
        ]
        for key, value in mutations:
            with self.subTest(key=key):
                pin = copy.deepcopy(self.pin)
                pin[key] = value
                with self.assertRaises(ValueError):
                    validate_pin(pin)
        pin = copy.deepcopy(self.pin)
        pin["extra"] = "unexpected"
        with self.assertRaises(ValueError):
            validate_pin(pin)
        with self.assertRaises(ValueError):
            validate_pin([])

    def test_application_to_pinned_clean_source(self):
        validate_pin(self.pin)
        override = os.environ.get("BITWARDEN_ORG_KEYS_SOURCE")
        source = Path(override) if override else ROOT / "build/SDKCache/bitwarden-sdk-5cf9198"
        if not source.exists() and not override:
            self.skipTest("pinned SDK cache absent; set BITWARDEN_ORG_KEYS_SOURCE to a clean pinned checkout")
        self.assertTrue(source.is_dir(), f"SDK source does not exist: {source}")
        self.assertEqual(run("git", "rev-parse", "HEAD", cwd=source), COMMIT)
        self.assertEqual(run("git", "rev-parse", "HEAD^{tree}", cwd=source), TREE)
        self.assertEqual(run("git", "status", "--porcelain", "--untracked-files=all", cwd=source), "", "SDK source must be clean")
        with tempfile.TemporaryDirectory(prefix="organization-keys-layer-") as directory:
            clone = Path(directory) / "sdk"
            run("git", "clone", "--quiet", "--no-hardlinks", str(source.resolve()), str(clone))
            self.assertEqual(run("git", "rev-parse", "HEAD", cwd=clone), COMMIT)
            for layer in [*LAYERS, PATCH]:
                run("git", "apply", "--check", str(ROOT / layer), cwd=clone)
                run("git", "apply", str(ROOT / layer), cwd=clone)
            run("git", "diff", "--check", cwd=clone)


if __name__ == "__main__":
    unittest.main()
