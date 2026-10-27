"""Pure SDK9 profile and source-inventory guards; no build or network."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SDK8_TEST = ROOT / 'Tests/NativeBitwardenSDK8PackageTests/test_strict_sdk_package.py'
spec = importlib.util.spec_from_file_location('sdk8_package_guards', SDK8_TEST)
sdk8 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sdk8)
builder = sdk8.builder
WORK = ROOT / 'build/NativeBitwardenStrictSDK9'
PIN = ROOT / 'ThirdParty/BitwardenStrictEditSpike/service-sdk-package.pin.json'
CANDIDATE = ROOT / 'ThirdParty/BitwardenStrictEditSpike/strict-service-shapes.candidate.json'
BASE_TRANSITION = {
    'crates/bitwarden-api-api/src/apis/sync_api.rs': '12b394da2ec6d42d75b5e693cd2da4b6d966821022728e821119d700d936679e',
    'crates/bitwarden-pm/src/lib.rs': '2fd41f89bfb38e394156bf90e072330e72356d3eaa7a9e7464e9661a3873d6b9',
    'crates/bitwarden-vault/src/cipher/cipher.rs': '4a257657195751cb7e0572b3c844a89477e08c3c7302c3f829f0946aeea28c3a',
}


class ServiceSDKPackageTests(unittest.TestCase):
    def setUp(self):
        WORK.mkdir(parents=True, exist_ok=True)
        self.pin = builder.json_bytes(PIN.read_bytes())
        self.candidate = builder.json_bytes(CANDIDATE.read_bytes())
        self.base = sdk8.make_pin()
        self.base['changedSourceSHA256'] = dict(self.pin['changedSourceSHA256'])
        self.base['changedSourceSHA256'].update(BASE_TRANSITION)
        self.base['changedPaths'] = sorted(self.base['changedSourceSHA256'])
        self.base['dependencyChanges'] = copy.deepcopy(self.pin['dependencyChanges'])

    def test_pinned_profiles_and_private_transition(self):
        self.assertEqual(hashlib.sha256(PIN.read_bytes()).hexdigest(), builder.SERVICE_PIN_SHA256)
        self.assertEqual(hashlib.sha256(CANDIDATE.read_bytes()).hexdigest(), builder.SERVICE_CANDIDATE_SHA256)
        old = copy.deepcopy(self.base)
        final = builder.validate_service_pin(self.pin, self.base, self.candidate)
        self.assertEqual(self.base, old)
        self.assertEqual(final['candidateGitTree'], builder.SERVICE_TREE)
        self.assertEqual(final['changedSourceSHA256']['crates/bitwarden-pm/src/lib.rs'],
                         self.candidate['changedSourceSha256']['crates/bitwarden-pm/src/lib.rs'])
        self.assertNotEqual(final['changedSourceSHA256']['crates/bitwarden-pm/src/lib.rs'],
                            self.base['changedSourceSHA256']['crates/bitwarden-pm/src/lib.rs'])
        self.assertEqual(final['candidateCargoLockSHA256'], self.base['candidateCargoLockSHA256'])
        with self.assertRaises(ValueError): builder.validate_pin(self.pin)
        with self.assertRaises(ValueError): builder.validate_service_pin(self.base, self.base, self.candidate)
        with self.assertRaises(AttributeError): builder.SDK9_PROFILE.name = 'sdk8'
        self.assertNotEqual(builder.SDK8_PROFILE.work, builder.SDK9_PROFILE.work)
        self.assertNotEqual(builder.SDK8_PROFILE.pin, builder.SDK9_PROFILE.pin)

    def test_service_pin_rejects_crossing_and_drift(self):
        for key, value in [('profile', 'sdk8'), ('accepted', True), ('integrationReady', 0),
                           ('baseTree', '0' * 40), ('candidateGitTree', '0' * 40),
                           ('candidateCargoLockSHA256', '0' * 64), ('sourceManifestEntries', True),
                           ('sourceManifestSHA256', '0' * 64), ('fullDiffSHA256', '0' * 64),
                           ('sdk8PinSHA256', '0' * 64), ('serviceCandidateSHA256', '0' * 64),
                           ('serviceReviewSHA256', '0' * 64), ('patches', []),
                           ('primarySha256', {}), ('changedPaths', []), ('dependencyChanges', [])]:
            bad = copy.deepcopy(self.pin); bad[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                builder.validate_service_pin(bad, self.base, self.candidate)
        bad = copy.deepcopy(self.pin); bad['patches'][9]['sha256'] = '0' * 64
        with self.assertRaises(ValueError): builder.validate_service_pin(bad, self.base, self.candidate)
        bad = copy.deepcopy(self.base); bad['candidateGitTree'] = builder.SERVICE_TREE
        with self.assertRaises(ValueError): builder.validate_service_pin(self.pin, bad, self.candidate)

    def test_candidate_ancestry_and_inventory_rejected(self):
        for key, value in [('baseTree', '0' * 40), ('sourceCommit', '0' * 40), ('schema', True),
                           ('candidateStatus', 'READY'), ('integrationReady', True),
                           ('patchSha256', '0' * 64), ('baselinePatches', []),
                           ('changedPaths', []), ('changedSourceSha256', {}),
                           ('primarySha256', {}), ('primaryPaths', {})]:
            bad = copy.deepcopy(self.candidate); bad[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                builder.validate_service_pin(self.pin, self.base, bad)

    def test_service_review_exact_and_json_duplicates_rejected(self):
        review = {k: copy.deepcopy(v) for k, v in self.pin.items() if k != 'serviceReviewSHA256'}
        builder.validate_service_review(review, self.pin)
        for key, value in [('baseTree', '0' * 40), ('candidateGitTree', '0' * 40),
                           ('sourceManifestEntries', True), ('primarySha256', {}), ('patches', [])]:
            bad = copy.deepcopy(review); bad[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): builder.validate_service_review(bad, self.pin)
        with self.assertRaises(ValueError): builder.validate_service_review(dict(review, extra=True), self.pin)
        with self.assertRaises(ValueError): builder.json_bytes(b'{"profile":"sdk9","profile":"sdk8"}')

    def test_primary_inventory_detects_extra_changed_and_symlink(self):
        with tempfile.TemporaryDirectory(dir=WORK) as directory:
            root = Path(directory).resolve(); (root / 'one').write_bytes(b'original')
            candidate = {'primarySha256': {'one': hashlib.sha256(b'original').hexdigest()}}
            builder.verify_primary_sources(root, candidate)
            (root / 'extra').write_bytes(b'x')
            with self.assertRaises(ValueError): builder.verify_primary_sources(root, candidate)
            (root / 'extra').unlink(); (root / 'one').write_bytes(b'drift')
            with self.assertRaises(ValueError): builder.verify_primary_sources(root, candidate)
            (root / 'one').unlink(); (root / 'one').symlink_to(root / 'missing')
            with self.assertRaises(ValueError): builder.verify_primary_sources(root, candidate)

    def test_exact_source_inventory_when_explicitly_supplied(self):
        raw = os.environ.get('ARCUSIS_SDK9_SOURCE')
        if raw is None: self.skipTest('owned source not supplied')
        if not raw: self.fail('empty source path')
        root = Path(raw)
        files, digest, count = builder.file_inventory(root, exclude_git=True)
        self.assertEqual((digest, count), (builder.SERVICE_MANIFEST, builder.SOURCE_ENTRIES))
        for name, expected in self.pin['changedSourceSHA256'].items():
            self.assertEqual(files.get(name), expected, name)

    def test_primary_sources_when_explicitly_supplied(self):
        raw = os.environ.get('ARCUSIS_SDK9_PRIMARY')
        if raw is None: self.skipTest('primary sources not supplied')
        if not raw: self.fail('empty primary path')
        builder.verify_primary_sources(Path(raw), self.candidate)


if __name__ == '__main__':
    unittest.main()
