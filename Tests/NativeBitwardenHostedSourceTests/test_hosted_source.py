import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('hosted_source', ROOT / 'scripts/prepare-native-bitwarden-hosted-source.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class Response(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


class HostedSourceTests(unittest.TestCase):
    def test_download_checks_checksum_size_and_exclusive_output(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            target = root / 'archive'
            opener = type('Opener', (), {'open': lambda self, request, timeout: Response(b'abc')})()
            with patch.object(MODULE.urllib.request, 'build_opener', return_value=opener):
                MODULE.download('https://example.invalid/object', target, hashlib.sha256(b'abc').hexdigest(), 3)
                with self.assertRaises(ValueError):
                    MODULE.download('https://example.invalid/object', target, hashlib.sha256(b'abc').hexdigest(), 3)
                with self.assertRaises(ValueError):
                    MODULE.download('https://example.invalid/object', root / 'bad', '0' * 64, 3)
                with self.assertRaises(ValueError):
                    MODULE.download('https://example.invalid/object', root / 'large', '0' * 64, 2)
                with self.assertRaises(ValueError):
                    MODULE.download('http://example.invalid/object', root / 'plain', '0' * 64, 3)

    def test_archive_rejects_traversal_duplicate_and_links(self):
        prefix = 'rust-1.98.0-aarch64-apple-darwin/'
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for mode in ('valid', 'traversal', 'duplicate', 'link'):
                archive = root / (mode + '.tar.xz')
                with tarfile.open(archive, 'w:xz') as bundle:
                    name = prefix + ('../escape' if mode == 'traversal' else 'install.sh')
                    item = tarfile.TarInfo(name)
                    if mode == 'link':
                        item.type = tarfile.SYMTYPE
                        item.linkname = '/tmp/escape'
                        bundle.addfile(item)
                    else:
                        data = b'#!/bin/sh\n'
                        item.size = len(data)
                        item.mode = 0o755
                        bundle.addfile(item, io.BytesIO(data))
                        if mode == 'duplicate':
                            bundle.addfile(item, io.BytesIO(data))
                if mode == 'valid':
                    self.assertTrue((MODULE.extract_toolchain(archive, root / mode) / 'install.sh').is_file())
                else:
                    with self.assertRaises(ValueError):
                        MODULE.extract_toolchain(archive, root / mode)

    def test_rejects_unsafe_primary_names(self):
        for name in ('', '.', '..', '../x', '/x', 'a/b', 'a\\b', 'a\x00b'):
            with self.assertRaises(ValueError):
                MODULE.path_component(name)
        self.assertEqual(MODULE.path_component('CipherData.cs'), 'CipherData.cs')

    def test_redirects_cannot_downgrade_tls_or_add_credentials(self):
        handler = MODULE.HTTPSRedirect()
        for url in ('http://example.invalid/file', 'https://user:password@example.invalid/file'):
            with self.assertRaisesRegex(ValueError, 'insecure download redirect'):
                handler.redirect_request(None, None, 302, '', {}, url)

    def test_download_enforces_total_deadline(self):
        with tempfile.TemporaryDirectory() as temp:
            opener = type('Opener', (), {'open': lambda self, request, timeout: Response(b'abc')})()
            with patch.object(MODULE.urllib.request, 'build_opener', return_value=opener), \
                 patch.object(MODULE.time, 'monotonic', side_effect=[0, 1801]):
                with self.assertRaisesRegex(TimeoutError, 'download deadline exceeded'):
                    MODULE.download('https://example.invalid/object', Path(temp).resolve() / 'late', '0' * 64, 4)

    def test_reviewed_input_rejects_symlink_and_parent_symlink(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            folder = root / 'folder'
            folder.mkdir()
            source = folder / 'input'
            source.write_text('data')
            self.assertEqual(MODULE.regular(source), source)
            link = root / 'link'
            link.symlink_to(source)
            with self.assertRaises(ValueError):
                MODULE.regular(link)
            parent = root / 'parent'
            parent.symlink_to(folder, target_is_directory=True)
            with self.assertRaises(ValueError):
                MODULE.regular(parent / 'input')


if __name__ == '__main__':
    unittest.main()
