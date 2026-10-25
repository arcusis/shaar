"""Fixture ownership, certificate identity, and real loopback TLS verification."""

from datetime import timedelta
import hashlib
import http.server
import importlib.util
import ipaddress
import os
from pathlib import Path
import shutil
import ssl
import stat
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request

from cryptography import x509
from cryptography.hazmat.primitives import serialization
from cryptography.x509.oid import ExtendedKeyUsageOID


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('vault_tls', ROOT / 'scripts/vault_tls.py')
tls = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = tls
spec.loader.exec_module(tls)


class VaultTLSTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='arcusis-engine-probe-')).resolve()
        self.addCleanup(shutil.rmtree, self.root)
        self.root.chmod(0o700)
        self.marker = self.root / '.arcusis-probe'
        self.marker.write_bytes(tls.MARKER)
        self.marker.chmod(0o600)

    def test_owned_marked_root(self):
        self.assertEqual(tls.validated_probe_root(self.root), self.root)

    def test_foreign_owner_and_fifo_marker_rejected(self):
        with patch.object(tls.os, 'getuid', return_value=os.getuid() + 1):
            with self.assertRaises(ValueError):
                tls.create_fixture_tls(self.root)
        self.marker.unlink()
        os.mkfifo(self.marker, mode=0o600)
        with self.assertRaises(ValueError):
            tls.create_fixture_tls(self.root)
        self.assertFalse((self.root / 'vault-tls').exists())

    def test_missing_wrong_or_public_marker(self):
        self.marker.unlink()
        with self.assertRaises(ValueError):
            tls.create_fixture_tls(self.root)
        self.marker.write_bytes(b'foreign')
        self.marker.chmod(0o600)
        with self.assertRaises(ValueError):
            tls.create_fixture_tls(self.root)
        self.marker.write_bytes(tls.MARKER)
        self.marker.chmod(0o644)
        with self.assertRaises(ValueError):
            tls.create_fixture_tls(self.root)
        self.assertFalse((self.root / 'vault-tls').exists())

    def test_public_root_symlink_and_nested_root_rejected(self):
        self.root.chmod(0o755)
        with self.assertRaises(ValueError):
            tls.create_fixture_tls(self.root)
        self.root.chmod(0o700)
        nested = self.root / 'arcusis-engine-probe-nested'
        nested.mkdir(mode=0o700)
        with self.assertRaises(ValueError):
            tls.create_fixture_tls(nested)
        alias = self.root.with_name(self.root.name + '-alias')
        alias.symlink_to(self.root, target_is_directory=True)
        self.addCleanup(alias.unlink)
        with self.assertRaises(ValueError):
            tls.create_fixture_tls(alias)

    def test_linked_marker_and_preexisting_tls_rejected(self):
        saved = self.root / 'marker-original'
        self.marker.rename(saved)
        self.marker.symlink_to(saved)
        with self.assertRaises(ValueError):
            tls.create_fixture_tls(self.root)
        self.marker.unlink()
        os.link(saved, self.marker)
        with self.assertRaises(ValueError):
            tls.create_fixture_tls(self.root)
        self.marker.unlink()
        saved.rename(self.marker)
        (self.root / 'vault-tls').symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(FileExistsError):
            tls.create_fixture_tls(self.root)
        self.assertFalse((self.root / 'private-key.pem').exists())

    def test_certificate_private_permissions_scope_lifetime_and_key_identity(self):
        material = tls.create_fixture_tls(self.root)
        certificate = x509.load_pem_x509_certificate(material.certificate.read_bytes())
        key = serialization.load_pem_private_key(material.private_key.read_bytes(), password=None)
        for path in (material.certificate, material.private_key):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(material.certificate.parent.stat().st_mode), 0o700)
        self.assertEqual(certificate.public_key().public_numbers(), key.public_key().public_numbers())
        sans = certificate.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
        self.assertEqual(list(sans), [x509.IPAddress(ipaddress.ip_address('127.0.0.1'))])
        self.assertFalse(certificate.extensions.get_extension_for_class(x509.BasicConstraints).value.ca)
        self.assertIn(ExtendedKeyUsageOID.SERVER_AUTH,
                      certificate.extensions.get_extension_for_class(x509.ExtendedKeyUsage).value)
        self.assertLessEqual(certificate.not_valid_after_utc - certificate.not_valid_before_utc,
                             timedelta(hours=6, minutes=2))
        spki = key.public_key().public_bytes(serialization.Encoding.DER,
                                             serialization.PublicFormat.SubjectPublicKeyInfo)
        self.assertEqual(material.spki_sha256, tls.base64.b64encode(hashlib.sha256(spki).digest()).decode())
        original = material.private_key.read_bytes()
        with self.assertRaises(FileExistsError):
            tls.create_fixture_tls(self.root)
        self.assertTrue(material.private_key.read_bytes() == original)

    def test_real_https_client_scoped_trust_and_unrelated_certificate_rejection(self):
        material = tls.create_fixture_tls(self.root)

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'fixture-tls-ok')

            def log_message(self, *_):
                pass

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(material.certificate, material.private_key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            url = f'https://127.0.0.1:{server.server_port}/alive'
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                urllib.request.HTTPSHandler(context=material.client_context()))
            with opener.open(url, timeout=3) as response:
                self.assertEqual(response.read(), b'fixture-tls-ok')
            other_root = Path(tempfile.mkdtemp(prefix='arcusis-engine-probe-')).resolve()
            self.addCleanup(shutil.rmtree, other_root)
            other_root.chmod(0o700)
            (other_root / '.arcusis-probe').write_bytes(tls.MARKER)
            (other_root / '.arcusis-probe').chmod(0o600)
            unrelated = tls.create_fixture_tls(other_root).client_context()
            bad = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                urllib.request.HTTPSHandler(context=unrelated))
            with self.assertRaises(urllib.error.URLError) as raised:
                bad.open(url, timeout=3)
            self.assertIsInstance(raised.exception.reason, ssl.SSLCertVerificationError)
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=3)
        self.assertFalse(worker.is_alive())


if __name__ == '__main__':
    unittest.main()
