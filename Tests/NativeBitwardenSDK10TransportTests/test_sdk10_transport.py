import hashlib
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SDK9_CONSUMER = ROOT / 'Tests/NativeBitwardenSDK9TransportTests/strict_service_consumer.swift'
SPEC = importlib.util.spec_from_file_location('sdk10_transport', ROOT / 'scripts/test-native-bitwarden-sdk10-transport.py')
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
            raise ValueError('unsafe input')
        return path

    @staticmethod
    def digest(path):
        return digest(FakeHelper.regular(path))

    @staticmethod
    def read_json(path):
        def unique(pairs):
            result = {}
            for key, value in pairs:
                if key in result: raise ValueError('duplicate key')
                result[key] = value
            return result
        return json.loads(FakeHelper.regular(path).read_bytes(), object_pairs_hook=unique)

    @staticmethod
    def validate_package(path, mode, expected):
        manifest = FakeHelper.read_json(path / 'build-manifest.json')
        if (digest(path / 'build-manifest.json') != expected or manifest.get('mode') != mode or
            manifest.get('testOnly') is not (mode == 'debug') or
            digest(path / 'payload') != manifest['fileSHA256']['payload']):
            raise ValueError('package tamper')
        return {'manifest': expected, 'files': manifest['fileSHA256']}


class SDK10TransportTests(unittest.TestCase):
    def test_binary_path_accepts_warning_and_rejects_unsafe_or_ambiguous_paths(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            scratch = root / 'scratch'
            directory = scratch / 'debug'
            directory.mkdir(parents=True)
            output = f'warning: harmless package warning\n{directory}\n'.encode()
            self.assertEqual(MODULE.parse_bin_path(output, scratch),
                             (directory, ['warning: harmless package warning']))
            with self.assertRaises(ValueError):
                MODULE.parse_bin_path(f'{directory}\n{directory}\n'.encode(), scratch)
            with self.assertRaises(ValueError):
                MODULE.parse_bin_path(f'{root}\n'.encode(), scratch)
            link = scratch / 'link'
            link.symlink_to(directory, target_is_directory=True)
            with self.assertRaises(ValueError):
                MODULE.parse_bin_path(f'{link}\n'.encode(), scratch)
            with self.assertRaises(ValueError):
                MODULE.parse_bin_path(b'warning: no path\n', scratch)

    def test_derived_consumer_uses_verified_source_and_exact_anchors(self):
        original = SDK9_CONSUMER.read_bytes()
        result = MODULE.derive_consumer(original).decode()
        self.assertIn('strict-sdk10-totp-', result)
        self.assertIn('strict-sdk9-negative=passed', result)
        self.assertIn('strict-sdk8-consumer=passed', result)
        self.assertIn('updated.login?.totp == (totpCase == "empty" ? nil : totpValue)', result)
        with self.assertRaises(ValueError): MODULE.derive_consumer(original + b' ')

    def test_transform_fails_when_anchor_missing_even_if_pin_matched(self):
        raw = b'incomplete'
        with patch.object(MODULE, 'CONSUMER_SHA', hashlib.sha256(raw).hexdigest()):
            with self.assertRaises(ValueError): MODULE.derive_consumer(raw)

    def test_verified_import_rejects_modified_or_symlink(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            source = root / 'helper.py'
            source.write_text('value = 7\n')
            value = digest(source)
            self.assertEqual(MODULE.load_module(source, value, 'sdk10_fake').value, 7)
            source.write_text('value = 8\n')
            with self.assertRaises(ValueError): MODULE.load_module(source, value, 'sdk10_fake')
            link = root / 'link.py'
            link.symlink_to(source)
            with self.assertRaises(ValueError): MODULE.load_module(link, digest(source), 'sdk10_fake')

    def test_checkpoint_package_receipt_and_payload_tamper(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            for name in MODULE.OWNED:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(name)
            checkpoint = root / 'checkpoint.json'
            checkpoint.write_text(json.dumps({'schema': 1, 'files': {name: digest(root / name) for name in MODULE.OWNED}}))
            helper = root / 'helper.py'; helper.write_text('helper')
            runner = root / 'runner.py'; runner.write_text('runner')
            consumer = root / 'consumer.swift'; consumer.write_bytes(SDK9_CONSUMER.read_bytes())
            extractor = root / 'extractor'; extractor.write_bytes(b'extractor')
            sdk_source = root / 'sdk'
            vector = sdk_source / 'crates/bitwarden-core/src/client/test_accounts.rs'
            vector.parent.mkdir(parents=True); vector.write_bytes(b'vector')
            hashes = {}
            for mode in ('debug', 'release'):
                package = root / mode; package.mkdir()
                (package / 'payload').write_text(mode)
                manifest = {'mode': mode, 'testOnly': mode == 'debug', 'profile': 'sdk10-empty-totp',
                            'candidateGitTree': MODULE.TREE, 'normalizationPatchSHA256': MODULE.PATCH,
                            'normalizationCandidateSHA256': MODULE.CANDIDATE,
                            'fileSHA256': {'payload': digest(package / 'payload')}}
                (package / 'build-manifest.json').write_text(json.dumps(manifest))
                hashes[mode] = digest(package / 'build-manifest.json')
            receipt = root / 'receipt.json'
            receipt.write_text(json.dumps({'profile': 'sdk10-empty-totp', 'candidateGitTree': MODULE.TREE,
                'normalizationPatchSHA256': MODULE.PATCH, 'normalizationCandidateSHA256': MODULE.CANDIDATE,
                'packages': {name: {'manifestSHA256': value} for name, value in hashes.items()}}))
            args = SimpleNamespace(checkpoint=checkpoint, checkpoint_sha256=digest(checkpoint),
                helper=helper, sdk9_runner=runner, consumer=consumer, receipt=receipt, receipt_sha256=digest(receipt),
                debug=root / 'debug', release=root / 'release', debug_manifest_sha256=hashes['debug'],
                release_manifest_sha256=hashes['release'], sdk_source=sdk_source, extractor=extractor)
            with patch.object(MODULE, 'ROOT', root), patch.object(MODULE, 'HELPER_SHA', digest(helper)), patch.object(MODULE, 'SDK9_RUNNER_SHA', digest(runner)):
                self.assertEqual(set(MODULE.inputs(FakeHelper, args)['packages']), {'debug', 'release'})
                args.checkpoint_sha256 = '0' * 64
                with self.assertRaises(ValueError): MODULE.inputs(FakeHelper, args)
                args.checkpoint_sha256 = digest(checkpoint)
                (root / 'debug/payload').write_text('changed')
                with self.assertRaises(ValueError): MODULE.inputs(FakeHelper, args)
                (root / 'debug/payload').write_text('debug')
                receipt.write_text('{}')
                with self.assertRaises(ValueError): MODULE.inputs(FakeHelper, args)


if __name__ == '__main__':
    unittest.main()
