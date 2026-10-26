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
PIN = ROOT / 'ThirdParty/BitwardenSyncSpike/organization-key-replacement.pin.json'
PATCH = 'ThirdParty/BitwardenSyncSpike/organization-key-replacement.patch'
COMMIT = '5cf919837e83b71c2508bf99344ea57cf5f84e88'
TREE = '9af9432aefeed6796e40e5019ffdc8600f3381e9'
LAYERS = {
    'ThirdParty/BitwardenAuthSpike/identity-mfa.patch': '850c53c73c710772b338bc88760543f66562119984e25bcf0337bfa986842a91',
    'ThirdParty/BitwardenKeyClearSpike/clear-crypto-keys.patch': 'f62fb617c615570d1a4280fd459af8b081caa758ad50fe4f57ebd7b34bdc2bf4',
    'ThirdParty/BitwardenSyncSpike/sync.patch': '26c6c57921ade94d4b6bed4b1627bf879ee6665fe23b5462b4b10a79633c7533',
    'ThirdParty/BitwardenSyncSpike/organization-keys.patch': 'b61303ecba50f6b1e75a083324e231878ae80d5663593302fede22dbd785cf1d',
}
FILES = [
    'Cargo.lock', 'crates/bitwarden-core/Cargo.toml',
    'crates/bitwarden-core/src/client/builder.rs', 'crates/bitwarden-core/src/client/client.rs',
    'crates/bitwarden-core/src/client/encryption_settings.rs', 'crates/bitwarden-core/src/client/internal.rs',
    'crates/bitwarden-core/src/key_management/crypto.rs', 'crates/bitwarden-core/src/key_management/crypto_client.rs',
    'crates/bitwarden-core/src/key_management/mod.rs',
    'crates/bitwarden-core/src/key_management/org_replacement_tests.rs',
    'crates/bitwarden-uniffi/src/crypto.rs', 'crates/bitwarden-uniffi/src/lib.rs',
    'crates/bitwarden-unlock/src/unlock_client.rs',
]
POLICY = 'strict clients opt in before unlock; host uses completed paired snapshots and invalidates vault access on sync failure; legacy offline rehydration remains enabled'


def run(*args: str, cwd: Path | None = None) -> str:
    return subprocess.run(args, cwd=cwd, check=True, text=True, capture_output=True).stdout.strip()


def validate(pin: dict) -> None:
    expected = {'schema': 1, 'accepted': False, 'compiled': False, 'integration_ready': False,
                'repository': 'https://github.com/bitwarden/sdk-internal', 'sourceCommit': COMMIT,
                'sourceTree': TREE, 'prerequisites': [{'file': p, 'sha256': h} for p, h in LAYERS.items()],
                'patchFile': PATCH, 'changedFiles': FILES, 'rustToolchain': '1.90-aarch64-apple-darwin',
                'target': 'aarch64-apple-darwin', 'policy': POLICY}
    if not isinstance(pin, dict) or set(pin) != set(expected) | {'patchSHA256', 'patchBytes'}:
        raise ValueError('invalid pin shape')
    for key, value in expected.items():
        if type(pin[key]) is not type(value) or pin[key] != value:
            raise ValueError(f'invalid {key}')
    payload = (ROOT / PATCH).read_bytes()
    if type(pin['patchBytes']) is not int or pin['patchBytes'] != len(payload) or pin['patchSHA256'] != hashlib.sha256(payload).hexdigest():
        raise ValueError('invalid patch digest or size')
    for path, digest in LAYERS.items():
        if hashlib.sha256((ROOT / path).read_bytes()).hexdigest() != digest:
            raise ValueError('invalid prerequisite')
    paths = [line.split('\t')[2] for line in run('git', 'apply', '--numstat', str(ROOT / PATCH)).splitlines()]
    if paths != FILES:
        raise ValueError('invalid patch scope')


class ReplacementPatchTests(unittest.TestCase):
    def test_metadata_and_hashes(self):
        validate(json.loads(PIN.read_text()))

    def test_rejects_metadata_mutation(self):
        original = json.loads(PIN.read_text())
        for key, value in [('accepted', True), ('compiled', True), ('integration_ready', True),
                           ('sourceTree', '0' * 40), ('patchFile', '../outside'), ('patchBytes', True),
                           ('prerequisites', list(reversed(original['prerequisites']))), ('changedFiles', [])]:
            altered = copy.deepcopy(original)
            altered[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate(altered)

    def test_layers_apply_to_exact_source(self):
        validate(json.loads(PIN.read_text()))
        source = Path(os.environ.get('BITWARDEN_REPLACEMENT_SOURCE', str(ROOT / 'build/SDKCache/bitwarden-sdk-5cf9198')))
        if not source.exists() and 'BITWARDEN_REPLACEMENT_SOURCE' not in os.environ:
            self.skipTest('pinned source cache absent')
        self.assertEqual(run('git', 'rev-parse', 'HEAD', cwd=source), COMMIT)
        self.assertEqual(run('git', 'rev-parse', 'HEAD^{tree}', cwd=source), TREE)
        self.assertEqual(run('git', 'status', '--porcelain', '--untracked-files=all', cwd=source), '')
        work = ROOT / 'build/org-key-replacement'
        work.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='layer-test-', dir=work) as tmp:
            archive = Path(tmp) / 'source.tar'
            with archive.open('wb') as out:
                subprocess.run(['git', 'archive', COMMIT], cwd=source, stdout=out, check=True)
            dest = Path(tmp) / 'sdk'
            dest.mkdir()
            with tarfile.open(archive) as tar:
                tar.extractall(dest, filter='data')
            # Initialize an isolated repository so git apply cannot resolve the outer checkout.
            run('git', 'init', '-q', cwd=dest)
            for patch in [*LAYERS, PATCH]:
                run('git', 'apply', '--check', str(ROOT / patch), cwd=dest)
                run('git', 'apply', str(ROOT / patch), cwd=dest)


if __name__ == '__main__':
    unittest.main()
