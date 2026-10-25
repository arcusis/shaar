"""Short-lived loopback TLS material for marked disposable vault fixtures only.

No OS trust-store, DNS, proxy, VPN or browser configuration changes are made here.
"""

import base64
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import hashlib
import ipaddress
import os
from pathlib import Path
import ssl
import stat
import tempfile

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID


MARKER = b'arcusis-engine-probe-v1\n'


def validated_probe_root(root: Path) -> Path:
    original = Path(root)
    canonical = original.resolve()
    try:
        details = original.lstat()
        if (not stat.S_ISDIR(details.st_mode) or details.st_uid != os.getuid()
                or stat.S_IMODE(details.st_mode) != 0o700
                or canonical.parent != Path(tempfile.gettempdir()).resolve()
                or not canonical.name.startswith('arcusis-engine-probe-')):
            raise ValueError
        descriptor = os.open(canonical / '.arcusis-probe',
                             os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
        try:
            marker = os.fstat(descriptor)
            if (not stat.S_ISREG(marker.st_mode) or marker.st_uid != os.getuid()
                    or marker.st_nlink != 1 or stat.S_IMODE(marker.st_mode) != 0o600
                    or marker.st_size != len(MARKER) or os.read(descriptor, len(MARKER) + 1) != MARKER):
                raise ValueError
        finally:
            os.close(descriptor)
    except (OSError, ValueError):
        raise ValueError('TLS fixture requires an owned, private, marked disposable root') from None
    return canonical


@dataclass(frozen=True)
class FixtureTLS:
    certificate: Path
    private_key: Path
    spki_sha256: str

    def client_context(self) -> ssl.SSLContext:
        """Trust this generated certificate for this client context only."""
        return ssl.create_default_context(cafile=str(self.certificate))


def create_fixture_tls(root: Path) -> FixtureTLS:
    root = validated_probe_root(root)
    directory = root / 'vault-tls'
    # Never overwrite a previous fixture key or follow a preexisting directory/link.
    directory.mkdir(mode=0o700)
    certificate_file = directory / 'certificate.pem'
    private_file = directory / 'private-key.pem'
    private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'Arcusis disposable loopback fixture')])
    now = datetime.now(timezone.utc)
    certificate = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
                   .public_key(private.public_key()).serial_number(x509.random_serial_number())
                   .not_valid_before(now - timedelta(minutes=1)).not_valid_after(now + timedelta(hours=6))
                   .add_extension(x509.SubjectAlternativeName([
                       x509.IPAddress(ipaddress.ip_address('127.0.0.1'))]), critical=False)
                   .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
                   .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
                   .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=False,
                       key_encipherment=True, data_encipherment=False, key_agreement=False,
                       key_cert_sign=False, crl_sign=False, encipher_only=False, decipher_only=False), critical=True)
                   .sign(private, hashes.SHA256()))
    material = (
        (private_file, private.private_bytes(serialization.Encoding.PEM,
                     serialization.PrivateFormat.PKCS8, serialization.NoEncryption())),
        (certificate_file, certificate.public_bytes(serialization.Encoding.PEM)),
    )
    for path, contents in material:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        with os.fdopen(descriptor, 'wb') as output:
            output.write(contents)
    spki = private.public_key().public_bytes(serialization.Encoding.DER,
                                            serialization.PublicFormat.SubjectPublicKeyInfo)
    fingerprint = base64.b64encode(hashlib.sha256(spki).digest()).decode('ascii')
    return FixtureTLS(certificate_file, private_file, fingerprint)
