import hashlib
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('sdk9_transport', ROOT / 'scripts/test-native-bitwarden-sdk9-transport.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class FakeHelper:
    VECTOR_SHA = hashlib.sha256(b'vector').hexdigest()
    EXTRACTOR_SHA = hashlib.sha256(b'extractor').hexdigest()

    @staticmethod
    def regular(path):
        if path.is_symlink() or not path.is_file():
            raise ValueError('unsafe file')
        return path

    @staticmethod
    def digest(path):
        return digest(FakeHelper.regular(path))

    @staticmethod
    def read_json(path):
        return json.loads(FakeHelper.regular(path).read_text(), object_pairs_hook=unique)

    @staticmethod
    def validate_package(root, mode, expected):
        manifest = FakeHelper.read_json(root / 'build-manifest.json')
        if (FakeHelper.digest(root / 'build-manifest.json') != expected or
            manifest.get('mode') != mode or manifest.get('testOnly') is not (mode == 'debug') or
            FakeHelper.digest(root / 'payload') != manifest['fileSHA256']['payload']):
            raise ValueError('package tamper')
        return {'manifest': expected, 'files': manifest['fileSHA256']}


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate key')
        result[key] = value
    return result


class SDK9InputTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        for name in MODULE.OWNED:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name)
        self.helper = self.root / 'helper.py'
        self.helper.write_text('helper')
        self.extractor = self.root / 'extractor.py'
        self.extractor.write_bytes(b'extractor')
        self.sdk = self.root / 'sdk'
        vector = self.sdk / 'crates/bitwarden-core/src/client/test_accounts.rs'
        vector.parent.mkdir(parents=True)
        vector.write_bytes(b'vector')
        self.manifests = {}
        for mode in ('debug', 'release'):
            directory = self.root / mode
            directory.mkdir()
            (directory / 'payload').write_bytes(mode.encode())
            manifest = {'mode': mode, 'testOnly': mode == 'debug', 'profile': 'sdk9-service-shapes',
                        'candidateGitTree': MODULE.TREE, 'serviceCandidateSHA256': MODULE.SERVICE_CANDIDATE,
                        'servicePatchSHA256': MODULE.SERVICE_PATCH,
                        'fileSHA256': {'payload': digest(directory / 'payload')}}
            (directory / 'build-manifest.json').write_text(json.dumps(manifest))
            self.manifests[mode] = digest(directory / 'build-manifest.json')
        receipt = {'profile': 'sdk9-service-shapes', 'candidateGitTree': MODULE.TREE,
                   'serviceCandidateSHA256': MODULE.SERVICE_CANDIDATE,
                   'servicePatchSHA256': MODULE.SERVICE_PATCH,
                   'packages': {mode: {'manifestSHA256': value} for mode, value in self.manifests.items()}}
        self.receipt = self.root / 'receipt.json'
        self.receipt.write_text(json.dumps(receipt))
        checkpoint = {'schema': 1, 'files': {name: digest(self.root / name) for name in MODULE.OWNED}}
        self.checkpoint = self.root / 'checkpoint.json'
        self.checkpoint.write_text(json.dumps(checkpoint))
        self.args = SimpleNamespace(helper=self.helper, receipt=self.receipt, checkpoint=self.checkpoint,
                                    checkpoint_sha256=digest(self.checkpoint), debug=self.root / 'debug',
                                    release=self.root / 'release', sdk_source=self.sdk, extractor=self.extractor)
        self.patches = [patch.object(MODULE, 'ROOT', self.root),
                        patch.object(MODULE, 'HELPER_SHA', digest(self.helper)),
                        patch.object(MODULE, 'RECEIPT_SHA', digest(self.receipt)),
                        patch.object(MODULE, 'MANIFESTS', self.manifests)]
        for item in self.patches:
            item.start()

    def tearDown(self):
        for item in reversed(self.patches):
            item.stop()
        self.temp.cleanup()

    def check(self):
        return MODULE.inputs(FakeHelper, self.args)

    def test_valid_checkpoint_and_two_modes(self):
        result = self.check()
        self.assertEqual(set(result['packages']), {'debug', 'release'})

    def test_checkpoint_digest_and_source_drift(self):
        self.args.checkpoint_sha256 = '0' * 64
        with self.assertRaises(ValueError): self.check()
        self.args.checkpoint_sha256 = digest(self.checkpoint)
        (self.root / MODULE.OWNED[0]).write_text('tampered')
        with self.assertRaises(ValueError): self.check()

    def test_missing_extra_and_duplicate_checkpoint_fields(self):
        data = json.loads(self.checkpoint.read_text())
        data['files'].pop(MODULE.OWNED[0])
        data['files']['extra'] = 'a' * 64
        self.checkpoint.write_text(json.dumps(data))
        self.args.checkpoint_sha256 = digest(self.checkpoint)
        with self.assertRaises(ValueError): self.check()
        self.checkpoint.write_text('{"schema":1,"schema":1,"files":{}}')
        self.args.checkpoint_sha256 = digest(self.checkpoint)
        with self.assertRaises(ValueError): self.check()

    def test_package_payload_and_mode_tamper(self):
        (self.root / 'debug/payload').write_text('tamper')
        with self.assertRaises(ValueError): self.check()

    def test_receipt_and_extractor_tamper(self):
        original = self.receipt.read_bytes()
        self.receipt.write_text('{}')
        with self.assertRaises(ValueError): self.check()
        self.receipt.write_bytes(original)
        self.extractor.write_text('tamper')
        with self.assertRaises(ValueError): self.check()

    def test_checkpoint_symlink_rejected(self):
        target = self.root / 'link.json'
        target.symlink_to(self.checkpoint)
        self.args.checkpoint = target
        with self.assertRaises(ValueError): self.check()

    def test_fault_payload_is_independent_and_preserves_ciphertext_format(self):
        seed = {'notes': '2.a|b|AAAA', 'login': {'uris': [{'uri': '2.x|y|zz', 'uriChecksum': None}]}}
        original = json.loads(json.dumps(seed))
        for fault in ('notes', 'history', 'checksum', 'mixed', 'valid'):
            result = MODULE.fault_payload(seed, fault)
            self.assertEqual(seed, original)
            self.assertIsNot(result, seed)
            self.assertIsNot(result['login'], seed['login'])
            if fault == 'notes': self.assertEqual(result['notes'], '2.a|b|BAAA')
            if fault == 'history': self.assertEqual(result['passwordHistory'][0]['password'], '2.a|b|BAAA')
            if fault == 'checksum': self.assertEqual(result['login']['uris'][0]['uriChecksum'], '2.x|y|zz')
            if fault == 'mixed': self.assertIn('card', result)
        with self.assertRaises(ValueError): MODULE.fault_payload(seed, 'other')

    def test_verified_source_import_rejects_tamper_and_symlink(self):
        source = self.root / 'module.py'
        source.write_text('value = 7\n')
        pinned = digest(source)
        self.assertEqual(MODULE.load_module(source, pinned, 'source_probe').value, 7)
        source.write_text('value = 8\n')
        with self.assertRaises(ValueError): MODULE.load_module(source, pinned, 'source_probe')
        link = self.root / 'module-link.py'
        link.symlink_to(source)
        with self.assertRaises(ValueError): MODULE.load_module(link, digest(source), 'source_probe')


if __name__ == '__main__':
    unittest.main()
