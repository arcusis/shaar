"""Pure filesystem guards; importing the fixture performs no runtime work."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('strict_transport_fixture', ROOT / 'scripts/test-native-bitwarden-strict-writes.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

class StrictTransportGuards(unittest.TestCase):
    def setUp(self):
        parent = ROOT / "build/NativeBitwardenStrictSDK8Transport"
        parent.mkdir(parents=True, exist_ok=True)
        if parent.is_symlink(): raise RuntimeError("symlinked test parent")
        self.tmp = tempfile.TemporaryDirectory(dir=parent)
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def package(self, **changes):
        files = {
            'Frameworks/BitwardenSDK.xcframework/macos-arm64/libbitwarden_uniffi.dylib': b'synthetic library',
            'Frameworks/BitwardenSDK.xcframework/macos-arm64/Headers/Fake.h': b'synthetic header',
            'Sources/BitwardenFFI/include/Fake.h': b'synthetic header',
            'Sources/ArcusisBitwardenSDK/Fake.swift': b'synthetic source',
            'ThirdPartyNotices/LICENSE': b'synthetic license',
            'binary': b'synthetic binary',
        }
        for name, data in files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        hashes = {name: hashlib.sha256(data).hexdigest() for name, data in files.items()}
        manifest = {'schema': 1, 'accepted': False, 'integrationReady': False, 'mode': 'debug',
                    'testOnly': True, 'sourceCommit': MODULE.SOURCE_COMMIT,
                    'writeCandidateSHA256': MODULE.WRITE_CANDIDATE_SHA, 'architecture': 'arm64',
                    'minMacOS': '26.0', 'fileSHA256': hashes,
                    'dylibSHA256': hashes['Frameworks/BitwardenSDK.xcframework/macos-arm64/libbitwarden_uniffi.dylib'],
                    'generatedSHA256': {'Fake.swift': hashes['Sources/ArcusisBitwardenSDK/Fake.swift'],
                                        'Fake.h': hashes['Sources/BitwardenFFI/include/Fake.h'], 'Fake.modulemap': '0' * 64},
                    'generatedModules': ['Fake'], 'licenseSHA256': {'LICENSE': hashes['ThirdPartyNotices/LICENSE']}}
        manifest.update(changes)
        path = self.root / 'build-manifest.json'
        path.write_text(json.dumps(manifest))
        return MODULE.digest(path)

    def test_inventory_and_drift(self):
        expected = self.package()
        MODULE.validate_package(self.root, 'debug', expected)
        with self.assertRaisesRegex(MODULE.FixtureError, 'unsupported mode'):
            MODULE.validate_package(self.root, 'other', expected)
        (self.root / 'binary').write_bytes(b'drift')
        with self.assertRaisesRegex(MODULE.FixtureError, 'inventory'):
            MODULE.validate_package(self.root, 'debug', expected)

    def test_extra_symlink_and_special_rejected(self):
        expected = self.package()
        (self.root / 'extra').write_bytes(b'extra')
        with self.assertRaisesRegex(MODULE.FixtureError, 'inventory'):
            MODULE.validate_package(self.root, 'debug', expected)
        (self.root / 'extra').unlink()
        (self.root / 'link').symlink_to(self.root / 'binary')
        with self.assertRaisesRegex(MODULE.FixtureError, 'symlink'):
            MODULE.validate_package(self.root, 'debug', expected)
        (self.root / 'link').unlink()
        os.mkfifo(self.root / 'pipe')
        with self.assertRaisesRegex(MODULE.FixtureError, 'special'):
            MODULE.validate_package(self.root, 'debug', expected)

    def test_provenance_and_bool_types_fail(self):
        for changes in ({'schema': True}, {'testOnly': False}, {'integrationReady': True},
                        {'accepted': 0}, {'writeCandidateSHA256': '0' * 64}, {'dylibSHA256': '0' * 64}):
            with self.subTest(changes=changes):
                expected = self.package(**changes)
                with self.assertRaisesRegex(MODULE.FixtureError, 'provenance'):
                    MODULE.validate_package(self.root, 'debug', expected)

    def test_duplicate_json_and_unpinned_receipt_fail_closed(self):
        with self.assertRaisesRegex(MODULE.FixtureError, 'duplicate'):
            json.loads('{"a":1,"a":2}', object_pairs_hook=MODULE.unique)
        receipt = self.root / 'receipt.json'
        receipt.write_text('{}')
        with patch.object(MODULE, 'EXPECTED_RECEIPT_SHA256', None):
            with self.assertRaisesRegex(MODULE.FixtureError, 'pending'):
                MODULE.pinned_receipt(receipt)

    def test_paths_and_manifest_pin(self):
        for path in ('relative', '/absolute/../escape', '/absolute/./alias'):
            with self.subTest(path=path), self.assertRaises(Exception): MODULE.absolute(path)
        expected = self.package()
        with self.assertRaisesRegex(MODULE.FixtureError, 'manifest pin'):
            MODULE.validate_package(self.root, 'debug', '0' * 64)
        (self.root / 'build-manifest.json').unlink()
        with self.assertRaises(FileNotFoundError): MODULE.validate_package(self.root, 'debug', expected)
