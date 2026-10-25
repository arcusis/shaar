"""Synthetic Bitwarden fixture data only; never imported by the browser application.

Implements the legacy authenticated type-2 format supported by the pinned server/client.
No network requests, secret persistence, production encryption or command-line interface.
"""

import base64
import binascii
from dataclasses import dataclass
import hashlib
import hmac
import secrets
import uuid

from cryptography.hazmat.primitives import hashes, padding, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.kdf.hkdf import HKDFExpand


ITERATIONS = 600_000
MAX_BYTES = 1024 * 1024


def encode(value: bytes) -> str:
    return base64.b64encode(value).decode('ascii')


def _key(value: bytes, length: int) -> None:
    if not isinstance(value, bytes) or len(value) != length:
        raise ValueError('Invalid fixture key length')


def derive_master_key(password: str, email: str, iterations: int = ITERATIONS) -> bytes:
    if (not isinstance(password, str) or not password or len(password) > 1024
            or not isinstance(email, str) or not email.strip() or len(email) > 320
            or type(iterations) is not int or not 100_000 <= iterations <= 2_000_000):
        raise ValueError('Invalid fixture KDF inputs')
    return hashlib.pbkdf2_hmac('sha256', password.encode(), email.strip().lower().encode(),
                               iterations, dklen=32)


def authentication_hash(master_key: bytes, password: str) -> str:
    _key(master_key, 32)
    if not isinstance(password, str) or not password or len(password) > 1024:
        raise ValueError('Invalid fixture authentication input')
    return encode(hashlib.pbkdf2_hmac('sha256', master_key, password.encode(), 1, dklen=32))


def stretch_master_key(master_key: bytes) -> bytes:
    _key(master_key, 32)
    return b''.join(HKDFExpand(algorithm=hashes.SHA256(), length=32, info=label).derive(master_key)
                    for label in (b'enc', b'mac'))


def encrypt(key: bytes, plaintext: bytes) -> str:
    _key(key, 64)
    if not isinstance(plaintext, bytes) or len(plaintext) > MAX_BYTES:
        raise ValueError('Invalid fixture plaintext')
    iv = secrets.token_bytes(16)
    padder = padding.PKCS7(128).padder()
    padded = padder.update(plaintext) + padder.finalize()
    cipher = Cipher(algorithms.AES256(key[:32]), modes.CBC(iv)).encryptor()
    ciphertext = cipher.update(padded) + cipher.finalize()
    mac = hmac.digest(key[32:], iv + ciphertext, 'sha256')
    return '2.' + '|'.join(encode(part) for part in (iv, ciphertext, mac))


def decrypt(key: bytes, encrypted: str) -> bytes:
    _key(key, 64)
    if not isinstance(encrypted, str) or len(encrypted) > 2 * MAX_BYTES or not encrypted.startswith('2.'):
        raise ValueError('Invalid authenticated fixture ciphertext')
    try:
        parts = encrypted[2:].split('|')
        if len(parts) != 3:
            raise ValueError
        iv, ciphertext, mac = (base64.b64decode(part, validate=True) for part in parts)
        if ([encode(value) for value in (iv, ciphertext, mac)] != parts
                or len(iv) != 16 or len(mac) != 32
                or not ciphertext or len(ciphertext) % 16 or len(ciphertext) > MAX_BYTES + 16):
            raise ValueError
        expected = hmac.digest(key[32:], iv + ciphertext, 'sha256')
        if not hmac.compare_digest(mac, expected):
            raise ValueError
        cipher = Cipher(algorithms.AES256(key[:32]), modes.CBC(iv)).decryptor()
        padded = cipher.update(ciphertext) + cipher.finalize()
        unpadder = padding.PKCS7(128).unpadder()
        plaintext = unpadder.update(padded) + unpadder.finalize()
        if len(plaintext) > MAX_BYTES:
            raise ValueError
        return plaintext
    except (ValueError, binascii.Error):
        raise ValueError('Invalid authenticated fixture ciphertext') from None


@dataclass(frozen=True, repr=False)
class SyntheticVaultAccount:
    """Generated test material. Payloads and attributes must never enter reports/logs."""

    email: str
    password: str
    auth_hash: str
    user_key: bytes
    wrapped_user_key: str
    public_key: str
    encrypted_private_key: str

    @classmethod
    def generate(cls):
        email = uuid.uuid4().hex + '@arcusis-fixture.invalid'
        password = secrets.token_urlsafe(32)
        master_key = derive_master_key(password, email)
        user_key = secrets.token_bytes(64)
        private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        private_der = private.private_bytes(serialization.Encoding.DER,
                                            serialization.PrivateFormat.PKCS8,
                                            serialization.NoEncryption())
        public_der = private.public_key().public_bytes(serialization.Encoding.DER,
                                                       serialization.PublicFormat.SubjectPublicKeyInfo)
        return cls(email, password, authentication_hash(master_key, password), user_key,
                   encrypt(stretch_master_key(master_key), user_key), encode(public_der),
                   encrypt(user_key, private_der))

    def registration_payload(self, verification_token: str) -> dict:
        if not isinstance(verification_token, str) or not verification_token:
            raise ValueError('Missing fixture registration token')
        return dict(email=self.email, emailVerificationToken=verification_token,
                    kdf=0, kdfIterations=ITERATIONS, key=self.wrapped_user_key,
                    masterPasswordHash=self.auth_hash,
                    keys=dict(publicKey=self.public_key, encryptedPrivateKey=self.encrypted_private_key))

    def login_payload(self) -> dict:
        return dict(grant_type='password', client_id='browser', username=self.email,
                    password=self.auth_hash, scope='api offline_access',
                    deviceIdentifier=str(uuid.uuid4()), deviceName='Arcusis disposable fixture',
                    deviceType='2')
