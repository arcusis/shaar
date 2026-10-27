"""Fail closed on strict SDK write patch, source, ancestry, and lock drift."""
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch as mock_patch

ROOT = Path(__file__).resolve().parents[2]
WRITE_SHA = 'e030b6a6eab842b11a1de1f293e75e09aa9bfca73330752296a266d2d1fc5b77'
STAGE1_SHA = '559c0c0a3f3c2e0719d4543fc39e1f4f5998b145884e09255e6b36f38be93d66'
SOURCE_COMMIT = '5cf919837e83b71c2508bf99344ea57cf5f84e88'
PARENT_TREE = '0a934e609b3dfef012a3477d2973ace834b1a1c2'
PARENT_PATCHES = {'ThirdParty/BitwardenAuthSpike/identity-mfa.patch': '850c53c73c710772b338bc88760543f66562119984e25bcf0337bfa986842a91', 'ThirdParty/BitwardenKeyClearSpike/clear-crypto-keys.patch': 'f62fb617c615570d1a4280fd459af8b081caa758ad50fe4f57ebd7b34bdc2bf4', 'ThirdParty/BitwardenRefreshSpike/native-http-deadline.patch': '8ec29eb0694c0624788922950b878d05e324dc344fbcfb5d44f34f307b862b87', 'ThirdParty/BitwardenRefreshSpike/refresh.patch': 'dbbade935ba424c56bbbe788ff87403c8404af1bd733a1e9a0175f34b836b6e8', 'ThirdParty/BitwardenSyncSpike/organization-key-replacement.patch': '4079044d3bd8dd3e8427ec86a1b2901704e4a08d2491dd67dbbf06dd2778294b', 'ThirdParty/BitwardenSyncSpike/organization-keys.patch': 'b61303ecba50f6b1e75a083324e231878ae80d5663593302fede22dbd785cf1d', 'ThirdParty/BitwardenSyncSpike/sync.patch': '26c6c57921ade94d4b6bed4b1627bf879ee6665fe23b5462b4b10a79633c7533'}
PARENT_ORDER = ['ThirdParty/BitwardenAuthSpike/identity-mfa.patch', 'ThirdParty/BitwardenKeyClearSpike/clear-crypto-keys.patch', 'ThirdParty/BitwardenSyncSpike/sync.patch', 'ThirdParty/BitwardenSyncSpike/organization-keys.patch', 'ThirdParty/BitwardenSyncSpike/organization-key-replacement.patch', 'ThirdParty/BitwardenRefreshSpike/refresh.patch', 'ThirdParty/BitwardenRefreshSpike/native-http-deadline.patch']
PARENT_SOURCES = {'Cargo.lock': 'c26d9daadc41872aab76083d2a42a757e2887d366be0c53b546b7fc1aa7355be', 'crates/bitwarden-api-api/src/apis/sync_api.rs': '12b394da2ec6d42d75b5e693cd2da4b6d966821022728e821119d700d936679e', 'crates/bitwarden-pm/Cargo.toml': 'e16e91bcb4adbcc18e93a3923affe90bd091746d8441b4ba41b929bee11d181e', 'crates/bitwarden-pm/src/lib.rs': '39da27d24cb69bcbb1820c39bf9ded162a197e27ae4d712f054b97196d1e3ec4', 'crates/bitwarden-sync/src/handler.rs': '18f15893dfd46d24770fe2faafdb13a44ecef24d6e8104f085460bfd50e983b3', 'crates/bitwarden-sync/src/sync_client.rs': 'c38521d91502b3e745ba4969cecbf500476aa1aa586078544efd8707348f8e53', 'crates/bitwarden-uniffi/src/vault/ciphers.rs': '5d606d57275124cdc49d0b3b04e650b4a302d0a5077c0bcb2df1ff0b75e60487', 'crates/bitwarden-vault/src/cipher/cipher.rs': '4a257657195751cb7e0572b3c844a89477e08c3c7302c3f829f0946aeea28c3a', 'crates/bitwarden-vault/src/cipher/cipher_client/mod.rs': 'c7ec63d73e51e10c739158e5ad3b7b2ffcce2122646b441dcaecfd92e65930a6', 'crates/bitwarden-vault/src/password_history.rs': '1daf67bd250de6af88e7f704e09fc484e5b38ed525fcecd919f70c7c4f1b5a43'}
WRITE_SOURCES = {'Cargo.lock': '48cef19482dfc18bbaf67e233b756a0b2a8e1551e558384893f0c05d3d7efd3e', 'crates/bitwarden-core/src/client/builder.rs': 'cfe4bc8496624d492d5007b240205d1ae7422bfbdef50e49c129a5d82b671598', 'crates/bitwarden-core/src/client/internal.rs': 'd6e19006b40226c79812f5a2531dbe8dc23f0996623381cd5e2cc251ae4fc124', 'crates/bitwarden-pm/Cargo.toml': '724e43c39dff39d8cd3015390d699b37115945cc97116c8a5fe52b4de5d8546b', 'crates/bitwarden-pm/src/lib.rs': '2fd41f89bfb38e394156bf90e072330e72356d3eaa7a9e7464e9661a3873d6b9', 'crates/bitwarden-uniffi/src/vault/ciphers.rs': '2ea65661f63d4f0af3420f16966cab3a6f3bf1c2ff8314aaac9ce1e7d9315855', 'crates/bitwarden-vault/src/cipher/cipher_client/mod.rs': 'b54e1aee28c00ed6eeeb5bbe23c0f182b1c106c473343c6760b3bb93a799928b'}
ALLOWED = frozenset(WRITE_SOURCES)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_regular(root, relative):
    parts = relative.split("/")
    if not parts or any(p in ("", ".", "..") for p in parts) or "\\" in relative:
        raise ValueError("unsafe path")
    path = root
    for part in parts:
        path = path / part
        if path.is_symlink():
            raise ValueError("symlink")
    if not path.is_file():
        raise ValueError("missing file")
    return path.read_bytes()


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result


def patch_blocks(data):
    text = data.decode("utf-8", errors="strict")
    if any(s in text for s in ("GIT binary patch", "rename from ", "new file mode", "deleted file mode", "old mode ", "new mode ")):
        raise ValueError("unsupported patch operation")
    blocks = {}
    for part in text.split("diff --git ")[1:]:
        lines = part.splitlines()
        match = re.fullmatch(r"a/([^ ]+) b/([^ ]+)", lines[0])
        if not match or match[1] != match[2]:
            raise ValueError("invalid patch header")
        path = match[1]
        if path.startswith("/") or "\\" in path or any(p in ("", ".", "..") for p in path.split("/")) or path in blocks:
            raise ValueError("unsafe or duplicate path")
        if [x for x in lines if x.startswith("--- ")] != ["--- a/" + path] or [x for x in lines if x.startswith("+++ ")] != ["+++ b/" + path]:
            raise ValueError("mismatched file headers")
        blocks[path] = lines
    if not blocks:
        raise ValueError("empty patch")
    return blocks


def validate(manifest, patch):
    if type(manifest.get("schema")) is not int or manifest["schema"] != 1:
        raise ValueError("schema")
    if manifest.get("candidateStatus") != "SOURCE_CANDIDATE_REVIEW_REQUIRED" or manifest.get("integrationReady") is not False:
        raise ValueError("candidate status")
    if manifest.get("sourceCommit") != SOURCE_COMMIT or manifest.get("sdk7ParentTree") != PARENT_TREE:
        raise ValueError("source pin")
    if manifest.get("sdk7PatchOrder") != PARENT_ORDER or manifest.get("sdk7Patches") != PARENT_PATCHES:
        raise ValueError("SDK7 chain")
    if manifest.get("preparationPatchSha256") != STAGE1_SHA or manifest.get("preparationChangedSourceSha256") != PARENT_SOURCES:
        raise ValueError("preparation pin")
    if manifest.get("writePatchSha256") != WRITE_SHA or digest(patch) != WRITE_SHA:
        raise ValueError("write patch hash")
    if manifest.get("writeSourceSha256") != WRITE_SOURCES or manifest.get("writeChangedPaths") != sorted(ALLOWED):
        raise ValueError("source inventory")
    blocks = patch_blocks(patch)
    if set(blocks) != ALLOWED:
        raise ValueError("patch inventory")
    def edits(path):
        return [line for line in blocks[path] if line.startswith(("+", "-")) and not line.startswith(("+++", "---"))]
    if edits("Cargo.lock") != ['+ "serde_json",']:
        raise ValueError("unexpected lock delta")
    if edits("crates/bitwarden-pm/Cargo.toml") != ['+serde_json = { workspace = true }']:
        raise ValueError("unexpected dependency delta")


class StrictWritePatchGuards(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads(read_regular(ROOT, "ThirdParty/BitwardenStrictEditSpike/strict-write.candidate.json"), object_pairs_hook=unique)
        self.patch = read_regular(ROOT, "ThirdParty/BitwardenStrictEditSpike/strict-personal-write.patch")

    def test_exact_patch_parent_pins_and_lock_delta(self):
        validate(self.manifest, self.patch)
        sdk7_override = os.environ.get("ARCUSIS_SDK7_PATCH_ROOT")
        sdk7_root = Path(sdk7_override) if sdk7_override else ROOT
        if not sdk7_root.is_absolute() or sdk7_root.is_symlink():
            raise ValueError("invalid SDK7 root")
        for name, expected in PARENT_PATCHES.items():
            self.assertEqual(digest(read_regular(sdk7_root, name)), expected, name)
        override = os.environ.get("ARCUSIS_SDK8_PREPARATION_PATCH")
        if override:
            path = Path(override)
            if not path.is_absolute() or path.is_symlink():
                raise ValueError("invalid stage1 override")
            stage1 = path.read_bytes()
        else:
            stage1 = read_regular(ROOT, self.manifest["preparationPatch"])
        self.assertEqual(digest(stage1), STAGE1_SHA)
        source_override = os.environ.get("ARCUSIS_STRICT_WRITE_SOURCE")
        if source_override:
            source = Path(source_override)
            if not source.is_absolute() or source.is_symlink():
                raise ValueError("invalid source override")
            for name, expected in WRITE_SOURCES.items():
                self.assertEqual(digest(read_regular(source, name)), expected, name)

    def test_patch_drift_fails(self):
        with self.assertRaisesRegex(ValueError, "hash"):
            validate(self.manifest, self.patch + b"drift")

    def test_parent_and_source_inventory_drift_fail(self):
        bad = dict(self.manifest)
        bad["preparationPatchSha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "preparation"):
            validate(bad, self.patch)
        bad = dict(self.manifest)
        bad["writeSourceSha256"] = {}
        with self.assertRaisesRegex(ValueError, "inventory"):
            validate(bad, self.patch)

    def test_unsafe_duplicate_and_extra_paths_fail(self):
        for data in (b"diff --git a/../x b/../x\n", b"diff --git a/x b/y\n",
                     b"diff --git a/x b/x\n--- a/x\n+++ b/x\ndiff --git a/x b/x\n--- a/x\n+++ b/x\n",
                     b"diff --git a/x b/x\nGIT binary patch\n"):
            with self.subTest(data=data), self.assertRaises(ValueError):
                patch_blocks(data)
        extra = self.patch + (b"\ndiff --git a/unapproved b/unapproved\n"
                              b"--- a/unapproved\n+++ b/unapproved\n@@ -1 +1 @@\n-x\n+y\n")
        bad = dict(self.manifest)
        bad["writePatchSha256"] = digest(extra)
        with mock_patch(__name__ + ".WRITE_SHA", digest(extra)):
            with self.assertRaisesRegex(ValueError, "inventory"):
                validate(bad, extra)

    def test_lock_and_manifest_mutations_fail(self):
        mutated = self.patch.replace(b'+ "serde_json",', b'+ "serde_json",\n+ "unapproved",', 1)
        self.assertNotEqual(mutated, self.patch)
        bad = dict(self.manifest)
        bad["writePatchSha256"] = digest(mutated)
        with mock_patch(__name__ + ".WRITE_SHA", digest(mutated)):
            with self.assertRaisesRegex(ValueError, "lock delta"):
                validate(bad, mutated)
        for field, value, error in (("schema", True, "schema"), ("integrationReady", True, "candidate status"),
                                    ("integrationReady", 0, "candidate status"), ("candidateStatus", "READY", "candidate status")):
            bad = dict(self.manifest)
            bad[field] = value
            with self.subTest(field=field, value=value), self.assertRaisesRegex(ValueError, error):
                validate(bad, self.patch)
        with self.assertRaisesRegex(ValueError, "duplicate"):
            json.loads('{"schema":1,"schema":1}', object_pairs_hook=unique)
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp); (base / "real").mkdir(); (base / "real" / "file").write_bytes(b"fixture")
            (base / "link").symlink_to(base / "real", target_is_directory=True)
            for name in ("link/file", "../file", "/real/file"):
                with self.subTest(name=name), self.assertRaises(ValueError):
                    read_regular(base, name)


if __name__ == "__main__":
    unittest.main()
