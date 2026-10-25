import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[2]
MODULE_SPEC = importlib.util.spec_from_file_location(
    'build_vault_fixture', REPO / 'scripts/build_vault_fixture.py')
builder = importlib.util.module_from_spec(MODULE_SPEC)
MODULE_SPEC.loader.exec_module(builder)


class VaultFixtureBuilderTests(unittest.TestCase):
    prefix = 'vaultwarden-testcommit'

    def make_archive(self, entries=None):
        entries = entries or {
            f'{self.prefix}/Cargo.toml': ('file', b'[package]\n'),
            f'{self.prefix}/Cargo.lock': ('file', b'version = 3\n'),
            f'{self.prefix}/src/main.rs': ('file', b'fn main() {}\n'),
        }
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w:gz') as archive:
            for name, (kind, value) in (entries.items() if hasattr(entries, 'items') else entries):
                info = tarfile.TarInfo(name)
                if kind == 'file':
                    info.size = len(value)
                    archive.addfile(info, io.BytesIO(value))
                elif kind == 'dir':
                    info.type = tarfile.DIRTYPE
                    archive.addfile(info)
                elif kind == 'symlink':
                    info.type = tarfile.SYMTYPE
                    info.linkname = value
                    archive.addfile(info)
                elif kind == 'fifo':
                    info.type = tarfile.FIFOTYPE
                    archive.addfile(info)
                elif kind == 'hardlink':
                    info.type = tarfile.LNKTYPE
                    info.linkname = value
                    archive.addfile(info)
                elif kind == 'char':
                    info.type = tarfile.CHRTYPE
                    archive.addfile(info)
        return stream.getvalue()

    def open_archive(self, payload):
        return tarfile.open(fileobj=io.BytesIO(payload), mode='r:gz')

    def test_archive_rejects_escape_and_unsupported_types(self):
        for name, kind, value in (
                ('../outside', 'file', b'x'),
                (f'{self.prefix}/device', 'fifo', b''),
                (f'{self.prefix}/hardlink', 'hardlink', f'{self.prefix}/Cargo.toml'),
                (f'{self.prefix}/sub/link', 'symlink', '../../outside')):
            with self.subTest(name=name):
                payload = self.make_archive({name: (kind, value)})
                with self.open_archive(payload) as archive:
                    with self.assertRaises(RuntimeError):
                        builder.source_members(archive, self.prefix)

    def test_archive_accepts_explicit_trailing_slash_directories(self):
        payload = self.make_archive([
            (f'{self.prefix}/', ('dir', b'')),
            (f'{self.prefix}/src/', ('dir', b'')),
            (f'{self.prefix}/Cargo.toml', ('file', b'[package]\n')),
            (f'{self.prefix}/Cargo.lock', ('file', b'version = 3\n')),
            (f'{self.prefix}/src/main.rs', ('file', b'fn main() {}\n')),
        ])
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary)
            with self.open_archive(payload) as archive:
                members = builder.source_members(archive, self.prefix)
                archive.extractall(destination, members=members, filter='data')
                builder.verify_source(archive, destination, self.prefix)

    def test_archive_rejects_duplicate_conflicting_and_special_paths(self):
        cases = {
            'duplicate normalized path': [
                (f'{self.prefix}/src/', ('dir', b'')),
                (f'{self.prefix}/src', ('dir', b'')),
            ],
            'file used as parent': [
                (f'{self.prefix}/src', ('file', b'x')),
                (f'{self.prefix}/src/main.rs', ('file', b'y')),
            ],
            'file replaces directory': [
                (f'{self.prefix}/src/', ('dir', b'')),
                (f'{self.prefix}/src', ('file', b'x')),
            ],
            'child below symlink': [
                (f'{self.prefix}/src', ('symlink', 'Cargo.toml')),
                (f'{self.prefix}/src/main.rs', ('file', b'x')),
            ],
            'root is file': [(self.prefix, ('file', b'x'))],
            'character device': [(f'{self.prefix}/device', ('char', b''))],
        }
        for label, entries in cases.items():
            with self.subTest(case=label):
                with self.open_archive(self.make_archive(entries)) as archive:
                    with self.assertRaises(RuntimeError):
                        builder.source_members(archive, self.prefix)

    def test_internal_relative_symlink_is_supported(self):
        payload = self.make_archive({
            f'{self.prefix}/common.txt': ('file', b'common'),
            f'{self.prefix}/nested/link.txt': ('symlink', '../common.txt'),
        })
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary)
            with self.open_archive(payload) as archive:
                members = builder.source_members(archive, self.prefix)
                archive.extractall(destination, members=members, filter='data')
                builder.verify_source(archive, destination, self.prefix)
            self.assertTrue((destination / self.prefix / 'nested/link.txt').is_symlink())

    def test_source_mutation_and_unexpected_inputs_are_rejected(self):
        payload = self.make_archive()
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary)
            with self.open_archive(payload) as archive:
                members = builder.source_members(archive, self.prefix)
                archive.extractall(destination, members=members, filter='data')
                source = destination / self.prefix
                (source / 'src/main.rs').write_bytes(b'changed')
                with self.assertRaisesRegex(RuntimeError, 'differs'):
                    builder.verify_source(archive, destination, self.prefix)
                (source / 'src/main.rs').write_bytes(b'fn main() {}\n')
                (source / 'injected.rs').write_text('unexpected')
                with self.assertRaisesRegex(RuntimeError, 'unexpected or missing'):
                    builder.verify_source(archive, destination, self.prefix)

    def test_source_file_replaced_by_symlink_is_rejected(self):
        payload = self.make_archive()
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary)
            with self.open_archive(payload) as archive:
                members = builder.source_members(archive, self.prefix)
                archive.extractall(destination, members=members, filter='data')
                source_file = destination / self.prefix / 'src/main.rs'
                source_file.unlink()
                source_file.symlink_to('../Cargo.toml')
                with self.assertRaisesRegex(RuntimeError, 'replaced by a symlink'):
                    builder.verify_source(archive, destination, self.prefix)

    def run_cached_build(self, receipt, source_change=None):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        pin_file = root / 'pin.json'
        cache = root / 'cache'
        cache.mkdir()
        pin = self.cached_pin()
        pin_file.write_text(json.dumps(pin))
        archive_path = cache / 'vaultwarden-testcommit.tar.gz'
        archive_path.write_bytes(self.archive_payload)
        source = cache / self.prefix
        with self.open_archive(self.archive_payload) as archive:
            archive.extractall(cache, members=builder.source_members(archive, self.prefix), filter='data')
        if source_change is not None:
            (source / 'src/main.rs').write_bytes(source_change)
        binary = cache / 'target/ci/vaultwarden'
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b'old binary')
        receipt_path = cache / 'build-receipt.json'
        receipt_path.write_text(receipt if isinstance(receipt, str) else json.dumps(receipt))

        def mock_build(command, cwd, env, check):
            output = Path(env['CARGO_TARGET_DIR']) / 'ci/vaultwarden'
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_bytes(b'new binary')

        with patch.object(builder, 'REPO', root), \
                patch.object(builder, 'PIN_FILE', pin_file), \
                patch.object(builder, 'CACHE', cache), \
                patch.object(builder.subprocess, 'run', side_effect=mock_build) as build, \
                patch.object(builder.urllib.request, 'urlopen', side_effect=AssertionError('network')) as download:
            error = None
            try:
                builder.main()
            except RuntimeError as caught:
                error = caught
        return build.call_count, download.call_count, json.loads(receipt_path.read_text()), binary.read_bytes(), error

    def cached_pin(self):
        return {
            'sourceCommit': 'testcommit',
            'archiveURL': 'https://invalid.example/unused.tar.gz',
            'sha256': hashlib.sha256(self.archive_payload).hexdigest(),
            'version': 'test-version',
            'rustToolchain': '1.80.0',
            'features': ['sqlite'],
        }

    def valid_cached_receipt(self):
        pin = self.cached_pin()
        fingerprint = hashlib.sha256(json.dumps(pin).encode()).hexdigest()
        return {
            'schema': 1,
            'pinSHA256': fingerprint,
            'sourceCommit': pin['sourceCommit'],
            'rustToolchain': pin['rustToolchain'],
            'binarySHA256': hashlib.sha256(b'old binary').hexdigest(),
            'cargoLockSHA256': hashlib.sha256(b'version = 3\n').hexdigest(),
        }

    def test_invalid_receipts_rebuild_and_refresh_receipt(self):
        self.archive_payload = self.make_archive()
        base_receipt = self.valid_cached_receipt()
        for field, value in (
                ('pinSHA256', 'wrong-pin'),
                ('sourceCommit', 'othercommit'),
                ('rustToolchain', 'other-toolchain'),
                ('binarySHA256', 'wrong-binary'),
                ('schema', 2),
                ('schema', True),
                ('cargoLockSHA256', 'wrong-lock')):
            with self.subTest(field=field):
                receipt = dict(base_receipt)
                receipt[field] = value
                calls, downloads, refreshed, binary, error = self.run_cached_build(receipt)
                self.assertIsNone(error)
                self.assertEqual(calls, 1)
                self.assertEqual(downloads, 0)
                self.assertEqual(binary, b'new binary')
                self.assertEqual(refreshed['sourceCommit'], 'testcommit')
                self.assertEqual(refreshed['binarySHA256'], hashlib.sha256(binary).hexdigest())
        with self.subTest(field='malformed-json-value'):
            self.archive_payload = self.make_archive()
            calls, downloads, refreshed, binary, error = self.run_cached_build('[]')
            self.assertIsNone(error)
            self.assertEqual(calls, 1)
            self.assertEqual(downloads, 0)
            self.assertEqual(refreshed['schema'], 1)
        with self.subTest(field='malformed-json-file'):
            calls, downloads, refreshed, binary, error = self.run_cached_build('{ malformed')
            self.assertIsNone(error)
            self.assertEqual(calls, 1)
            self.assertEqual(downloads, 0)
            self.assertEqual(refreshed['schema'], 1)

    def test_valid_receipt_uses_cache_without_build_or_download(self):
        self.archive_payload = self.make_archive()
        calls, downloads, receipt, binary, error = self.run_cached_build(self.valid_cached_receipt())
        self.assertIsNone(error)
        self.assertEqual(calls, 0)
        self.assertEqual(downloads, 0)
        self.assertEqual(binary, b'old binary')
        self.assertEqual(receipt, self.valid_cached_receipt())

    def test_mutated_source_stops_build(self):
        self.archive_payload = self.make_archive()
        calls, downloads, receipt, binary, error = self.run_cached_build({}, source_change=b'changed')
        self.assertEqual(calls, 0)
        self.assertEqual(downloads, 0)
        self.assertIsInstance(error, RuntimeError)
        self.assertIn('differs', str(error))


if __name__ == '__main__':
    unittest.main()
