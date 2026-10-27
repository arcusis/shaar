"""Pure source-pin and inventory guards; no SDK, process, or network execution."""
import copy
import hashlib
import importlib.util
import json
import stat
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/build-native-bitwarden-strict-sdk.py'
WORK = ROOT / 'build/NativeBitwardenStrictSDK9/sdk8-guards'
spec = importlib.util.spec_from_file_location('strict_sdk_package', SCRIPT)
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


def make_pin():
    patches = [{'path': path, 'sha256': digest} for path, digest in builder.PATCHES]
    patches.append({'path': 'ThirdParty/BitwardenStrictEditSpike/strict-personal-write.patch', 'sha256': builder.WRITE_PATCH})
    return {'schema': 1, 'accepted': False, 'integrationReady': False,
            'sourceCommit': builder.COMMIT, 'sourceGitTree': builder.TREE,
            'sourceCargoLockSHA256': builder.BASE_LOCK, 'candidateGitTree': builder.CANDIDATE_TREE,
            'candidateCargoLockSHA256': builder.CANDIDATE_LOCK, 'sourceManifestSHA256': builder.SOURCE_MANIFEST,
            'sourceManifestEntries': builder.SOURCE_ENTRIES, 'fullDiffSHA256': builder.FULL_DIFF,
            'changedPaths': ['Cargo.lock', 'crates/example.rs'],
            'changedSourceSHA256': {'Cargo.lock': builder.CANDIDATE_LOCK, 'crates/example.rs': 'e' * 64},
            'patches': patches, 'writeCandidateSHA256': builder.WRITE_CANDIDATE, 'sourceReviewSHA256': builder.SOURCE_REVIEW,
            'licenseSHA256': builder.LICENSES.copy(), 'supportSHA256': builder.SUPPORT_SHA256,
            'dependencyChanges': [], 'cargoRegistrySHA256': builder.REGISTRY, 'cargoRegistryEntries': builder.REGISTRY_ENTRIES,
            'cargoGitSHA256': builder.GIT_CACHE, 'cargoGitEntries': builder.GIT_CACHE_ENTRIES,
            'consumerSHA256': builder.CONSUMER, 'consumerRequiredTokens': ['strictPreparePersonalLogin', 'strictPersonalUpdate'],
            'rustToolchain': '1.98.0', 'target': 'aarch64-apple-darwin', 'architecture': 'arm64', 'minMacOS': '26.0'}


class StrictSDKPackageTests(unittest.TestCase):
    def setUp(self):
        WORK.mkdir(parents=True, exist_ok=True)

    def test_pin_schema_type_source_and_patch_tampering(self):
        pin = make_pin()
        builder.validate_pin(pin)
        for key, value in [('schema', True), ('accepted', True), ('integrationReady', 0),
                           ('sourceCommit', '0' * 40), ('sourceGitTree', '0' * 40),
                           ('sourceCargoLockSHA256', '0' * 64), ('candidateGitTree', 'bad'),
                           ('sourceManifestSHA256', 'z' * 64), ('sourceManifestEntries', True),
                           ('cargoRegistryEntries', 0), ('cargoGitEntries', True),
                           ('cargoGitSHA256', 'z' * 64), ('rustToolchain', 'stable'),
                           ('target', 'x86_64-apple-darwin'), ('architecture', 'x86_64'),
                           ('minMacOS', '25.0'), ('licenseSHA256', {}),
                           ('supportSHA256', '0' * 64), ('changedPaths', ['../escape']),
                           ('changedSourceSHA256', {}), ('consumerRequiredTokens', [])]:
            altered = copy.deepcopy(pin)
            altered[key] = value
            with self.subTest(field=key), self.assertRaises(ValueError):
                builder.validate_pin(altered)
        for mutate in ('order', 'digest', 'duplicate', 'escape', 'missing'):
            altered = copy.deepcopy(pin)
            if mutate == 'order': altered['patches'][0], altered['patches'][1] = altered['patches'][1], altered['patches'][0]
            if mutate == 'digest': altered['patches'][7]['sha256'] = '0' * 64
            if mutate == 'duplicate': altered['patches'][8]['path'] = altered['patches'][7]['path']
            if mutate == 'escape': altered['patches'][8]['path'] = '../escape.patch'
            if mutate == 'missing': altered['patches'].pop()
            with self.subTest(patches=mutate), self.assertRaises(ValueError):
                builder.validate_pin(altered)
        with self.assertRaises(ValueError):
            builder.json_bytes(b'{"schema":1,"schema":1}')

    def test_explicit_pin_digest_and_unsafe_paths(self):
        with tempfile.TemporaryDirectory(dir=WORK) as tmp:
            root = Path(tmp).resolve()
            path = root / 'pin.json'
            raw = json.dumps(make_pin(), sort_keys=True).encode()
            path.write_bytes(raw)
            expected = hashlib.sha256(raw).hexdigest()
            self.assertEqual(builder.load_pin(path, expected)['sourceCommit'], builder.COMMIT)
            for wrong in ('0' * 64, '', 'x' * 64):
                with self.subTest(digest=wrong), self.assertRaises(ValueError):
                    builder.load_pin(path, wrong)
            symlink = root / 'alias.json'
            symlink.symlink_to(path)
            with self.assertRaises(ValueError):
                builder.load_pin(symlink, expected)
        for name in ('../escape', '/absolute', 'a//b', 'a/./b', 'a/../b', 'a\\b', 'a\nfile', ''):
            with self.subTest(path=name), self.assertRaises(ValueError):
                builder.safe_relative(name)

    def test_inventory_detects_extra_content_symlinks_and_special_files(self):
        with tempfile.TemporaryDirectory(dir=WORK) as tmp:
            root = Path(tmp).resolve()
            (root / 'nested').mkdir()
            (root / 'nested/a').write_text('first')
            files, original, count = builder.file_inventory(root)
            self.assertEqual(files, {'nested/a': hashlib.sha256(b'first').hexdigest()})
            self.assertEqual(count, 2)
            self.assertEqual(builder.validate_package_inventory(root, {'nested/a'}), files)
            (root / 'empty').mkdir()
            with self.assertRaisesRegex(ValueError, 'directory inventory'):
                builder.validate_package_inventory(root, {'nested/a'})
            self.assertNotEqual(original, builder.file_inventory(root)[1])
            (root / 'empty').rmdir()
            (root / 'nested/a').write_text('changed')
            self.assertNotEqual(original, builder.file_inventory(root)[1])
            (root / 'link').symlink_to(root / 'nested/a')
            with self.assertRaisesRegex(ValueError, 'symlink or special'):
                builder.file_inventory(root)
            (root / 'link').unlink()
            victim = root / 'nested/a'
            real_lstat = Path.lstat
            def fake_lstat(path):
                if path == victim:
                    return SimpleNamespace(st_mode=stat.S_IFIFO)
                return real_lstat(path)
            with mock.patch.object(Path, 'lstat', autospec=True, side_effect=fake_lstat):
                with self.assertRaisesRegex(ValueError, 'symlink or special'):
                    builder.file_inventory(root)

    def test_source_review_must_match_every_pinned_field(self):
        pin = make_pin()
        fields = ('sourceCommit', 'sourceGitTree', 'candidateGitTree', 'sourceManifestSHA256',
                  'sourceManifestEntries', 'fullDiffSHA256', 'changedPaths', 'changedSourceSHA256',
                  'candidateCargoLockSHA256', 'dependencyChanges', 'writeCandidateSHA256', 'patches')
        review = {key: copy.deepcopy(pin[key]) for key in fields}
        builder.validate_source_review(review, pin)
        for key, value in [('candidateGitTree', '0' * 40), ('sourceManifestEntries', True),
                           ('changedPaths', []), ('changedSourceSHA256', {}),
                           ('dependencyChanges', [{}]), ('patches', []),
                           ('writeCandidateSHA256', '0' * 64)]:
            altered = copy.deepcopy(review)
            altered[key] = value
            with self.subTest(field=key), self.assertRaises(ValueError):
                builder.validate_source_review(altered, pin)
        with self.assertRaises(ValueError):
            builder.validate_source_review(dict(review, unexpected=True), pin)

    def test_checkpoint_rejects_stale_wrong_or_extra_source(self):
        pin = make_pin()
        candidate = {'schema': 1, 'sourceCommit': builder.COMMIT, 'integrationReady': False,
                     'preparationPatchSha256': builder.PATCHES[7][1],
                     'writePatchSha256': pin['patches'][8]['sha256'],
                     'writeSourceSha256': {'crates/example.rs': 'e' * 64}}
        builder.validate_checkpoint(candidate, pin)
        for key, value in [('schema', True), ('sourceCommit', '0' * 40), ('integrationReady', True),
                           ('preparationPatchSha256', '0' * 64), ('writePatchSha256', '0' * 64),
                           ('writeSourceSha256', {}), ('writeSourceSha256', {'../escape': 'e' * 64}),
                           ('writeSourceSha256', {'crates/example.rs': '0' * 64}),
                           ('writeSourceSha256', {'crates/extra.rs': 'e' * 64})]:
            altered = copy.deepcopy(candidate)
            altered[key] = value
            with self.subTest(field=key, value=value), self.assertRaises(ValueError):
                builder.validate_checkpoint(altered, pin)

    def test_dependency_lock_delta_is_exact_and_remote_packages_unchanged(self):
        base = b'''version = 4\n[[package]]\nname = "local"\nversion = "1.0.0"\ndependencies = ["one"]\n[[package]]\nname = "remote"\nversion = "2.0.0"\nsource = "registry+https://example.invalid"\nchecksum = "aaa"\n'''
        final = base.replace(b'dependencies = ["one"]', b'dependencies = ["one", "two"]')
        allowed = [{'name': 'local', 'version': '1.0.0', 'before': ['one'], 'after': ['one', 'two']}]
        builder.validate_dependencies(base, final, allowed)
        for altered, delta in [(final, []), (final.replace(b'checksum = "aaa"', b'checksum = "bbb"'), allowed),
                               (final.replace(b'version = "2.0.0"', b'version = "2.0.1"'), allowed),
                               (base, allowed)]:
            with self.subTest(lock=altered[:25]), self.assertRaises(ValueError):
                builder.validate_dependencies(base, altered, delta)

    def test_compile_only_consumer_is_explicitly_pinned(self):
        source = (b'import Foundation\nimport ArcusisBitwardenSDK\n'
                  b'StrictPersonalPreparation StrictPersonalWriteOutcome '
                  b'strictPreparePersonalLogin strictPersonalUpdate')
        pin = make_pin()
        pin['consumerSHA256'] = hashlib.sha256(source).hexdigest()
        builder.validate_consumer(source, pin)
        with self.assertRaises(ValueError):
            builder.validate_consumer(source + b'changed', pin)
        altered = source.replace(b'strictPersonalUpdate', b'unrelated')
        pin['consumerSHA256'] = hashlib.sha256(altered).hexdigest()
        with self.assertRaisesRegex(ValueError, 'strict API'):
            builder.validate_consumer(altered, pin)


if __name__ == '__main__':
    unittest.main()
