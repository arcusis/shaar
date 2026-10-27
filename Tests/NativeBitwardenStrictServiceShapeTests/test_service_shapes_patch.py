"""Fail closed on service-shape candidate, ancestry and primary-source drift."""
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PATCH_SHA = '8917fd3a357dd3a075391ba9d9aeefbf5343f8a665aebf58c4bdb457ca80d76c'
SOURCE_HASHES = {'crates/bitwarden-api-api/src/apis/sync_api.rs': '85a5d8ba5721ceb5f8f4a98c03b742e1bb4ea64eb08eccf03175b9a409506e64', 'crates/bitwarden-pm/src/lib.rs': '64a6ad8e31fc6df7834ce0b32a299a57248fbc3e1418d2650aa7d9b96f8eee38', 'crates/bitwarden-vault/src/cipher/cipher.rs': 'b3a2c06a9d3ea1a300a5ea5d3cc94acbdb04768498bd04b9c85ddb5ec0143579'}
PRIMARY_HASHES = {'BitwardenApiStartup.cs': 'f6f8d5edbab88298bdd69bf7a4617b4a7e7b3e53b36266a5220d1fefc673aa20', 'CipherData.cs': 'c70d82936c5d5d2dfab1cb66a4d30c8047ec5710902420b361536e0c9fdb59b9', 'CipherFieldData.cs': '1d57095e665a3fee3666437c3ee7198acb101674e74957b193580bf0131e2191', 'CipherFieldModel.cs': 'be47b0c6ae1ee68d1bfdd757cab8819d6c0ce7cb201350d7dc7c185b0ccd6ea7', 'CipherLoginData.cs': 'ff274558fad5e275213e383e53bebb5433f9cd2cb8622a801ccf73c0ec26ab07', 'CipherLoginModel.cs': '13fa0586973cc60b0824071341fa6e2824e8230a4fcae97dbd57ddb27e2a5f22', 'CipherPasswordHistoryData.cs': '15245b3b4dd8bb16556f55f4de83813129f8447e2e25a954213e31282f06f888', 'CipherPasswordHistoryModel.cs': 'f079129837f77e276fb3354779546f9fb2d1b5352cf421d3da2def9e6b99cfbb', 'CipherPermissionsResponseModel.cs': 'e8830a03a3fc3db99684c0a77a56140f7fad203bf99f6fa588788825f6e00897', 'CipherRequestModel.cs': '2bf00f62aab1332a77c7483d00eecdbb75ef9591a501fa2e647bc6c24a74e317', 'CipherResponseModel.cs': '5d03b29732a34d3bb2952b7d291d7ea77a3830c7b526ae80a13a47358bdc48d3', 'CipherService.cs': '8afa818552819964d28bb40395b31b9684974a47686853021855c457c6ddf875', 'NormalCipherPermissions.cs': 'f7a1bd4ca3288d09a97610d63ada97b600bbda337a85e1d38bfd9d4ac0790834', 'vaultwarden-cipher-model.rs': 'c3ae6804d8dc2a6a914a9e9e95a97a98037d7f3cbde9421fc50ece10872c1c3a', 'vaultwarden-ciphers.rs': '18c4cb7fb77b548b90716634a9b8041ca33a7f68df3e76a7aeeaded229924553'}
PRIMARY_PATHS = {'BitwardenApiStartup.cs': 'src/Api/Startup.cs', 'CipherData.cs': 'src/Core/Vault/Models/Data/CipherData.cs', 'CipherFieldData.cs': 'src/Core/Vault/Models/Data/CipherFieldData.cs', 'CipherFieldModel.cs': 'src/Api/Vault/Models/CipherFieldModel.cs', 'CipherLoginData.cs': 'src/Core/Vault/Models/Data/CipherLoginData.cs', 'CipherLoginModel.cs': 'src/Api/Vault/Models/CipherLoginModel.cs', 'CipherPasswordHistoryData.cs': 'src/Core/Vault/Models/Data/CipherPasswordHistoryData.cs', 'CipherPasswordHistoryModel.cs': 'src/Api/Vault/Models/CipherPasswordHistoryModel.cs', 'CipherPermissionsResponseModel.cs': 'src/Api/Vault/Models/Response/CipherPermissionsResponseModel.cs', 'CipherRequestModel.cs': 'src/Api/Vault/Models/Request/CipherRequestModel.cs', 'CipherResponseModel.cs': 'src/Api/Vault/Models/Response/CipherResponseModel.cs', 'CipherService.cs': 'src/Core/Vault/Services/Implementations/CipherService.cs', 'NormalCipherPermissions.cs': 'src/Core/Vault/Authorization/Permissions/NormalCipherPermissions.cs', 'vaultwarden-cipher-model.rs': 'src/db/models/cipher.rs', 'vaultwarden-ciphers.rs': 'src/api/core/ciphers.rs'}
BASELINE_PATCHES = [{'path': 'ThirdParty/BitwardenAuthSpike/identity-mfa.patch', 'sha256': '850c53c73c710772b338bc88760543f66562119984e25bcf0337bfa986842a91'}, {'path': 'ThirdParty/BitwardenKeyClearSpike/clear-crypto-keys.patch', 'sha256': 'f62fb617c615570d1a4280fd459af8b081caa758ad50fe4f57ebd7b34bdc2bf4'}, {'path': 'ThirdParty/BitwardenSyncSpike/sync.patch', 'sha256': '26c6c57921ade94d4b6bed4b1627bf879ee6665fe23b5462b4b10a79633c7533'}, {'path': 'ThirdParty/BitwardenSyncSpike/organization-keys.patch', 'sha256': 'b61303ecba50f6b1e75a083324e231878ae80d5663593302fede22dbd785cf1d'}, {'path': 'ThirdParty/BitwardenSyncSpike/organization-key-replacement.patch', 'sha256': '4079044d3bd8dd3e8427ec86a1b2901704e4a08d2491dd67dbbf06dd2778294b'}, {'path': 'ThirdParty/BitwardenRefreshSpike/refresh.patch', 'sha256': 'dbbade935ba424c56bbbe788ff87403c8404af1bd733a1e9a0175f34b836b6e8'}, {'path': 'ThirdParty/BitwardenRefreshSpike/native-http-deadline.patch', 'sha256': '8ec29eb0694c0624788922950b878d05e324dc344fbcfb5d44f34f307b862b87'}, {'path': 'ThirdParty/BitwardenStrictEditSpike/strict-personal-edit.patch', 'sha256': '559c0c0a3f3c2e0719d4543fc39e1f4f5998b145884e09255e6b36f38be93d66'}, {'path': 'ThirdParty/BitwardenStrictEditSpike/strict-personal-write.patch', 'sha256': 'e030b6a6eab842b11a1de1f293e75e09aa9bfca73330752296a266d2d1fc5b77'}]
BASE_TREE = 'faa9b91b5013d5411a2519178609e92d6591948d'
SOURCE_COMMIT = '5cf919837e83b71c2508bf99344ea57cf5f84e88'


def digest(data): return hashlib.sha256(data).hexdigest()


def read_regular(root, name):
    parts = name.split('/')
    if not root.is_absolute() or not parts or any(x in ('', '.', '..') for x in parts) or '\\' in name:
        raise ValueError('unsafe path')
    for part in (root, *root.parents):
        if part.is_symlink(): raise ValueError('symlink')
    path = root
    for part in parts:
        path = path / part
        if path.is_symlink(): raise ValueError('symlink')
    if not path.is_file(): raise ValueError('missing regular file')
    return path.read_bytes()


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result: raise ValueError('duplicate JSON key')
        result[key] = value
    return result


def patch_paths(data):
    text = data.decode('utf-8', errors='strict')
    if any(token in text for token in ('GIT binary patch', 'rename from ', 'new file mode', 'deleted file mode', 'old mode ', 'new mode ')):
        raise ValueError('unsupported operation')
    result = set()
    for block in text.split('diff --git ')[1:]:
        lines = block.splitlines()
        match = re.fullmatch(r'a/([^ ]+) b/([^ ]+)', lines[0])
        if not match or match[1] != match[2]: raise ValueError('header')
        name = match[1]
        if name.startswith('/') or '\\' in name or any(x in ('', '.', '..') for x in name.split('/')) or name in result:
            raise ValueError('unsafe or duplicate path')
        if [x for x in lines if x.startswith('--- ')] != ['--- a/' + name] or [x for x in lines if x.startswith('+++ ')] != ['+++ b/' + name]:
            raise ValueError('header mismatch')
        result.add(name)
    return result


def validate(manifest, patch):
    if type(manifest.get('schema')) is not int or manifest['schema'] != 1:
        raise ValueError('schema')
    if manifest.get('candidateStatus') != 'SOURCE_CANDIDATE_REVIEW_REQUIRED' or manifest.get('integrationReady') is not False:
        raise ValueError('status')
    if manifest.get('sourceCommit') != SOURCE_COMMIT or manifest.get('baseTree') != BASE_TREE or manifest.get('baselinePatches') != BASELINE_PATCHES:
        raise ValueError('ancestry')
    if manifest.get('primaryCommits') != {'bitwarden':'5847df2f0f2112eb271bfd58ef1691c758029a60', 'vaultwarden':'0f44744ef86a2a7bea615af1c024044ce5736187'}:
        raise ValueError('provider commits')
    if manifest.get('primarySha256') != PRIMARY_HASHES or manifest.get('primaryPaths') != PRIMARY_PATHS:
        raise ValueError('primary inventory')
    if manifest.get('changedSourceSha256') != SOURCE_HASHES or manifest.get('changedPaths') != sorted(SOURCE_HASHES):
        raise ValueError('source inventory')
    if manifest.get('patchSha256') != PATCH_SHA or digest(patch) != PATCH_SHA:
        raise ValueError('patch hash')
    if patch_paths(patch) != set(SOURCE_HASHES): raise ValueError('patch paths')


def configured_roots(environ):
    keys = ('ARCUSIS_SERVICE_BASELINE_ROOT', 'ARCUSIS_SERVICE_SOURCE', 'ARCUSIS_SERVICE_PRIMARY')
    values = [environ.get(key) for key in keys]
    if all(value is None for value in values): return None
    if any(not value for value in values): raise ValueError('partial source configuration')
    return tuple(Path(value) for value in values)


class ServiceShapeGuards(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads(read_regular(ROOT, 'ThirdParty/BitwardenStrictEditSpike/strict-service-shapes.candidate.json'), object_pairs_hook=unique)
        self.patch = read_regular(ROOT, 'ThirdParty/BitwardenStrictEditSpike/strict-service-shapes.patch')

    def test_exact_pins(self):
        validate(self.manifest, self.patch)

    def test_exact_source_inventory_when_configured(self):
        roots = configured_roots(os.environ)
        if roots is None: self.skipTest('external source inputs not configured')
        baseline, source, primary = roots
        for entry in BASELINE_PATCHES:
            self.assertEqual(digest(read_regular(baseline, entry['path'])), entry['sha256'], entry['path'])
        for name, expected in SOURCE_HASHES.items(): self.assertEqual(digest(read_regular(source, name)), expected, name)
        for name, expected in PRIMARY_HASHES.items(): self.assertEqual(digest(read_regular(primary, name)), expected, name)

    def test_source_configuration_must_be_complete(self):
        self.assertIsNone(configured_roots({}))
        with self.assertRaisesRegex(ValueError, 'partial'):
            configured_roots({'ARCUSIS_SERVICE_SOURCE': '/tmp/source'})
        with self.assertRaisesRegex(ValueError, 'partial'):
            configured_roots({'ARCUSIS_SERVICE_BASELINE_ROOT': '', 'ARCUSIS_SERVICE_SOURCE': '/x', 'ARCUSIS_SERVICE_PRIMARY': '/y'})

    def test_patch_and_ancestry_drift_fail(self):
        with self.assertRaisesRegex(ValueError, 'patch hash'): validate(self.manifest, self.patch + b'drift')
        bad = dict(self.manifest); bad['baseTree'] = '0' * 40
        with self.assertRaisesRegex(ValueError, 'ancestry'): validate(bad, self.patch)

    def test_metadata_types_and_duplicate_json_fail(self):
        for key, value in [('schema', True), ('integrationReady', 0), ('candidateStatus', 'READY')]:
            bad = dict(self.manifest); bad[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): validate(bad, self.patch)
        with self.assertRaisesRegex(ValueError, 'duplicate'): json.loads('{"schema":1,"schema":1}', object_pairs_hook=unique)

    def test_unsafe_paths_and_duplicate_patch_blocks_fail(self):
        for data in (b'diff --git a/../x b/../x\n', b'diff --git a/x b/y\n',
                     b'diff --git a/x b/x\n--- a/x\n+++ b/x\ndiff --git a/x b/x\n--- a/x\n+++ b/x\n'):
            with self.subTest(data=data), self.assertRaises(ValueError): patch_paths(data)

    def test_symlink_and_traversal_fail(self):
        parent = ROOT / 'build/NativeBitwardenStrictServiceShapes'; parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=parent) as directory:
            root = Path(directory); (root / 'real').mkdir(); (root / 'real' / 'file').write_bytes(b'owned')
            (root / 'link').symlink_to(root / 'real', target_is_directory=True)
            for name in ('link/file', '../file', '/real/file'):
                with self.subTest(name=name), self.assertRaises(ValueError): read_regular(root, name)
