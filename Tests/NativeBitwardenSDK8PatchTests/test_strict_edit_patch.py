"""Guard the reviewed strict SDK patch and its exact seven-layer parent."""

import hashlib
import json
import re
import tempfile
import unittest
from unittest.mock import patch as mock_patch
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CANDIDATE = ROOT / "ThirdParty/BitwardenStrictEditSpike/strict-edit.candidate.json"
PATCH = ROOT / "ThirdParty/BitwardenStrictEditSpike/strict-personal-edit.patch"
PARENT_TREE = "0a934e609b3dfef012a3477d2973ace834b1a1c2"
SOURCE_COMMIT = "5cf919837e83b71c2508bf99344ea57cf5f84e88"
APPROVED_PATHS = frozenset({
    "Cargo.lock",
    "crates/bitwarden-pm/Cargo.toml",
    "crates/bitwarden-vault/src/cipher/cipher.rs",
    "crates/bitwarden-vault/src/cipher/cipher_client/mod.rs",
    "crates/bitwarden-vault/src/password_history.rs",
    "crates/bitwarden-api-api/src/apis/sync_api.rs",
    "crates/bitwarden-sync/src/sync_client.rs",
    "crates/bitwarden-sync/src/handler.rs",
    "crates/bitwarden-pm/src/lib.rs",
    "crates/bitwarden-uniffi/src/vault/ciphers.rs",
})
PATCH_SHA256 = "559c0c0a3f3c2e0719d4543fc39e1f4f5998b145884e09255e6b36f38be93d66"
PARENT_PATCHES = {
    "ThirdParty/BitwardenAuthSpike/identity-mfa.patch": "850c53c73c710772b338bc88760543f66562119984e25bcf0337bfa986842a91",
    "ThirdParty/BitwardenKeyClearSpike/clear-crypto-keys.patch": "f62fb617c615570d1a4280fd459af8b081caa758ad50fe4f57ebd7b34bdc2bf4",
    "ThirdParty/BitwardenRefreshSpike/native-http-deadline.patch": "8ec29eb0694c0624788922950b878d05e324dc344fbcfb5d44f34f307b862b87",
    "ThirdParty/BitwardenRefreshSpike/refresh.patch": "dbbade935ba424c56bbbe788ff87403c8404af1bd733a1e9a0175f34b836b6e8",
    "ThirdParty/BitwardenSyncSpike/organization-key-replacement.patch": "4079044d3bd8dd3e8427ec86a1b2901704e4a08d2491dd67dbbf06dd2778294b",
    "ThirdParty/BitwardenSyncSpike/organization-keys.patch": "b61303ecba50f6b1e75a083324e231878ae80d5663593302fede22dbd785cf1d",
    "ThirdParty/BitwardenSyncSpike/sync.patch": "26c6c57921ade94d4b6bed4b1627bf879ee6665fe23b5462b4b10a79633c7533",
}

PATCH_ORDER = [
    "ThirdParty/BitwardenAuthSpike/identity-mfa.patch",
    "ThirdParty/BitwardenKeyClearSpike/clear-crypto-keys.patch",
    "ThirdParty/BitwardenSyncSpike/sync.patch",
    "ThirdParty/BitwardenSyncSpike/organization-keys.patch",
    "ThirdParty/BitwardenSyncSpike/organization-key-replacement.patch",
    "ThirdParty/BitwardenRefreshSpike/refresh.patch",
    "ThirdParty/BitwardenRefreshSpike/native-http-deadline.patch",
]

def digest(data):
    return hashlib.sha256(data).hexdigest()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def read_regular(base, relative):
    parts = relative.split("/")
    if not parts or any(part in ("", ".", "..") for part in parts) or "\\" in relative:
        raise ValueError("unsafe path")
    path = base
    for part in parts:
        path = path / part
        if path.is_symlink():
            raise ValueError("symlink")
    if not path.is_file():
        raise ValueError("not a regular file")
    return path.read_bytes()

def parse_manifest(data):
    return json.loads(data, object_pairs_hook=unique_object)


def changed_paths(data):
    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise ValueError("non-UTF8 patch") from exc
    if "GIT binary patch" in text or "rename from " in text or "new file mode" in text or "deleted file mode" in text:
        raise ValueError("unsupported patch operation")
    paths = []
    for line in text.splitlines():
        if line.startswith("diff --git "):
            match = re.fullmatch(r"diff --git a/([^ ]+) b/([^ ]+)", line)
            if not match or match[1] != match[2]:
                raise ValueError("unsafe patch path")
            path = match[1]
            parts = path.split("/")
            if path.startswith("/") or any(part in ("", ".", "..") for part in parts) or "\\" in path:
                raise ValueError("unsafe patch path")
            if path in paths:
                raise ValueError("duplicate patch path")
            paths.append(path)
    if not paths:
        raise ValueError("empty patch")
    blocks = text.split("diff --git ")[1:]
    for path, block in zip(paths, blocks):
        lines = block.splitlines()
        old = [line for line in lines if line.startswith("--- ")]
        new = [line for line in lines if line.startswith("+++ ")]
        if old != ["--- a/" + path] or new != ["+++ b/" + path]:
            raise ValueError("mismatched patch headers")
        if any(line.startswith(("old mode ", "new mode ", "new file mode ", "deleted file mode ")) for line in lines):
            raise ValueError("unsupported patch mode")
    return paths


def verify(manifest, patch, expected_paths):
    if manifest.get("schema") != 1 or manifest.get("sourceCommit") != SOURCE_COMMIT:
        raise ValueError("invalid source pin")
    if manifest.get("parentTree") != PARENT_TREE or manifest.get("parentPatches") != PARENT_PATCHES or manifest.get("parentPatchOrder") != PATCH_ORDER:
        raise ValueError("invalid parent chain")
    if manifest.get("patchSha256") != PATCH_SHA256 or manifest.get("patchSha256") != digest(patch):
        raise ValueError("patch hash mismatch")
    paths = changed_paths(patch)
    if set(paths) != expected_paths or manifest.get("changedPaths") != sorted(paths):
        raise ValueError("patch inventory mismatch")


class StrictPatchGuards(unittest.TestCase):
    def test_reviewed_checkpoint_and_patch(self):
        manifest = parse_manifest(read_regular(ROOT, "ThirdParty/BitwardenStrictEditSpike/strict-edit.candidate.json"))
        self.assertEqual(manifest["approvedPaths"], sorted(APPROVED_PATHS))
        verify(manifest, read_regular(ROOT, "ThirdParty/BitwardenStrictEditSpike/strict-personal-edit.patch"), APPROVED_PATHS)
        for relative, expected in PARENT_PATCHES.items():
            self.assertEqual(digest(read_regular(ROOT, relative)), expected, relative)

    def test_rejects_digest_drift(self):
        manifest = parse_manifest(read_regular(ROOT, "ThirdParty/BitwardenStrictEditSpike/strict-edit.candidate.json"))
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            verify(manifest, read_regular(ROOT, "ThirdParty/BitwardenStrictEditSpike/strict-personal-edit.patch") + b"drift", APPROVED_PATHS)

    def test_rejects_parent_chain_drift(self):
        manifest = parse_manifest(read_regular(ROOT, "ThirdParty/BitwardenStrictEditSpike/strict-edit.candidate.json"))
        manifest["parentTree"] = "0" * 40
        with self.assertRaisesRegex(ValueError, "parent chain"):
            verify(manifest, read_regular(ROOT, "ThirdParty/BitwardenStrictEditSpike/strict-personal-edit.patch"), APPROVED_PATHS)

    def test_rejects_extra_path(self):
        manifest = parse_manifest(read_regular(ROOT, "ThirdParty/BitwardenStrictEditSpike/strict-edit.candidate.json"))
        patch = read_regular(ROOT, "ThirdParty/BitwardenStrictEditSpike/strict-personal-edit.patch") + (b"\ndiff --git a/unapproved b/unapproved\n"
                                      b"--- a/unapproved\n+++ b/unapproved\n@@ -1 +1 @@\n-x\n+y\n")
        manifest["patchSha256"] = digest(patch)
        with mock_patch(__name__ + ".PATCH_SHA256", digest(patch)):
            with self.assertRaisesRegex(ValueError, "inventory"):
                verify(manifest, patch, APPROVED_PATHS)

    def test_rejects_unsafe_and_duplicate_paths(self):
        for text in (b"diff --git a/../escape b/../escape\n",
                     b"diff --git a/a b/b\n",
                     b"diff --git a/a b/a\ndiff --git a/a b/a\n",
                     b"diff --git a/a b/a\nGIT binary patch\n"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                changed_paths(text)

    def test_rejects_symlinks_and_path_escapes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "real").mkdir()
            (root / "real" / "patch").write_bytes(b"fixture")
            (root / "link").symlink_to(root / "real", target_is_directory=True)
            self.assertEqual(read_regular(root, "real/patch"), b"fixture")
            for name in ("link/patch", "../real/patch", "/real/patch"):
                with self.subTest(name=name), self.assertRaises(ValueError):
                    read_regular(root, name)

    def test_rejects_duplicate_manifest_keys(self):
        with self.assertRaisesRegex(ValueError, "duplicate JSON key"):
            parse_manifest('{"schema":1,"schema":1}')


if __name__ == "__main__":
    unittest.main()
