"""Public SDK vectors plus synthetic-only crypto/account boundary checks."""

import base64
import hmac
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

from cryptography.hazmat.primitives import serialization


ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('vault_crypto', ROOT / 'scripts/vault_crypto.py')
crypto = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = crypto
spec.loader.exec_module(crypto)


# Public vectors, not account credentials. Source commit and hashes: sdk-reference.json.
class PublicVectorTests(unittest.TestCase):
    def test_sdk_authentication_vector_and_email_normalization(self):
        for email in ('test@bitwarden.com', 'TEST@bitwarden.com', ' test@bitwarden.com'):
            key = crypto.derive_master_key('asdfasdf', email, 100_000)
            self.assertEqual(crypto.authentication_hash(key, 'asdfasdf'),
                             'wmyadRMyBZOH7P/a/ucTCbSghKgdzDpPqUnu/DAVtSw=')

    def test_sdk_stretch_vector(self):
        key = bytes([31, 79, 104, 226, 150, 71, 177, 90, 194, 80, 172, 209, 17, 129, 132, 81,
                     138, 167, 69, 167, 254, 149, 2, 27, 39, 197, 64, 42, 22, 195, 86, 75])
        expected = bytes([111, 31, 178, 45, 238, 152, 37, 114, 143, 215, 124, 83, 135, 173,
                          195, 23, 142, 134, 120, 249, 61, 132, 163, 182, 113, 197, 189, 204,
                          188, 21, 237, 96, 221, 127, 206, 234, 101, 27, 202, 38, 86, 52, 34,
                          28, 78, 28, 185, 16, 48, 61, 127, 166, 209, 247, 194, 87, 232, 26,
                          48, 85, 193, 249, 179, 155])
        self.assertEqual(crypto.stretch_master_key(key), expected)

    def test_sdk_authenticated_encryption_vector(self):
        key = bytes(range(64))
        iv = bytes([216, 218, 36, 0, 196, 186, 150, 85, 49, 147, 110, 168, 185, 227, 42, 172])
        ciphertext = bytes([234, 77, 16, 15, 189, 82, 36, 188, 182, 88, 64, 67, 145, 94, 30,
                            178, 36, 235, 130, 67, 255, 207, 183, 168, 73, 231, 82, 122, 193,
                            139, 25, 129])
        mac = bytes([60, 78, 44, 111, 72, 233, 3, 6, 86, 250, 217, 242, 62, 229, 184, 221,
                     231, 150, 189, 44, 99, 189, 220, 55, 196, 194, 101, 60, 102, 195, 149, 130])
        encoded = '2.' + '|'.join(crypto.encode(part) for part in (iv, ciphertext, mac))
        self.assertEqual(crypto.decrypt(key, encoded), b'Bitwarden SDK test vector')
        with patch.object(crypto.secrets, 'token_bytes', return_value=iv):
            self.assertEqual(crypto.encrypt(key, b'Bitwarden SDK test vector'), encoded)


class CipherBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.key = bytes(range(64))

    def test_empty_unicode_and_block_boundaries(self):
        for plaintext in (b'', b'x', b'x' * 15, b'x' * 16, b'x' * 17, 'fixture \u2713'.encode()):
            with self.subTest(length=len(plaintext)):
                self.assertEqual(crypto.decrypt(self.key, crypto.encrypt(self.key, plaintext)), plaintext)

    def test_fresh_iv(self):
        self.assertNotEqual(crypto.encrypt(self.key, b'fixture'), crypto.encrypt(self.key, b'fixture'))

    def test_mac_is_checked_before_decryption(self):
        original = crypto.encrypt(self.key, b'fixture')
        for index in range(3):
            parts = original[2:].split('|')
            altered = bytearray(base64.b64decode(parts[index]))
            altered[0] ^= 1
            parts[index] = crypto.encode(altered)
            with self.subTest(part=index), patch.object(crypto, 'Cipher') as cipher:
                with self.assertRaisesRegex(ValueError, '^Invalid authenticated fixture ciphertext$'):
                    crypto.decrypt(self.key, '2.' + '|'.join(parts))
                cipher.assert_not_called()

    def test_wrong_account_key_rejected(self):
        with self.assertRaises(ValueError):
            crypto.decrypt(bytes(reversed(self.key)), crypto.encrypt(self.key, b'fixture'))

    def test_unsupported_malformed_and_noncanonical_encodings(self):
        valid = crypto.encrypt(self.key, b'fixture')
        for value in (None, '', valid.replace('2.', '0.', 1), valid.replace('2.', '7.', 1),
                      valid + '|extra', '2.!!!|AA==|AA==', '2.AA==|AA==|AA==',
                      valid.replace('==', '===', 1), '2.' + 'x' * (2 * crypto.MAX_BYTES)):
            with self.subTest(kind=type(value).__name__):
                with self.assertRaises(ValueError):
                    crypto.decrypt(self.key, value)

    def test_valid_mac_with_bad_padding_rejected(self):
        parts = crypto.encrypt(self.key, b'fixture')[2:].split('|')
        iv, ciphertext = (base64.b64decode(part) for part in parts[:2])
        iv = iv[:-1] + bytes([iv[-1] ^ 0xff])
        mac = hmac.digest(self.key[32:], iv + ciphertext, 'sha256')
        with self.assertRaises(ValueError):
            crypto.decrypt(self.key, '2.' + '|'.join(crypto.encode(p) for p in (iv, ciphertext, mac)))

    def test_key_lengths_kdf_limits_and_types(self):
        for key in (b'', b'x' * 32, b'x' * 63, b'x' * 65, None):
            with self.assertRaises(ValueError):
                crypto.encrypt(key, b'fixture')
        for iterations in (True, 0, 99_999, 2_000_001, '600000'):
            with self.assertRaises(ValueError):
                crypto.derive_master_key('fixture', 'fixture.invalid', iterations)
        for password, email in (('', 'fixture.invalid'), ('fixture', ''), (None, 'fixture.invalid')):
            with self.assertRaises(ValueError):
                crypto.derive_master_key(password, email)
        with self.assertRaises(ValueError):
            crypto.encrypt(self.key, b'x' * (crypto.MAX_BYTES + 1))


class SyntheticAccountTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.account = crypto.SyntheticVaultAccount.generate()

    def test_generated_material_unwraps_and_rsa_keys_match(self):
        account = self.account
        self.assertTrue(account.email.endswith('@arcusis-fixture.invalid'))
        self.assertGreaterEqual(len(account.password), 40)
        key = crypto.derive_master_key(account.password, account.email)
        self.assertTrue(hmac.compare_digest(
            crypto.decrypt(crypto.stretch_master_key(key), account.wrapped_user_key), account.user_key))
        private = serialization.load_der_private_key(
            crypto.decrypt(account.user_key, account.encrypted_private_key), password=None)
        public = serialization.load_der_public_key(base64.b64decode(account.public_key))
        self.assertEqual(private.public_key().public_numbers(), public.public_numbers())
        self.assertEqual(private.key_size, 2048)
        self.assertTrue(hmac.compare_digest(account.auth_hash, crypto.authentication_hash(key, account.password)))

    def test_account_repr_excludes_generated_material(self):
        representation = repr(self.account)
        self.assertTrue(all(value not in representation for value in (
            self.account.email, self.account.password, self.account.auth_hash,
            self.account.wrapped_user_key, self.account.encrypted_private_key)))

    def test_registration_and_login_use_hash_not_master_password(self):
        account = self.account
        registration = account.registration_payload('synthetic-test-token')
        login = account.login_payload()
        self.assertEqual(registration['kdfIterations'], 600_000)
        self.assertTrue(registration['key'] == account.wrapped_user_key)
        self.assertTrue(registration['masterPasswordHash'] == account.auth_hash)
        self.assertTrue(login['password'] == account.auth_hash)
        self.assertTrue(account.password not in str(registration))
        self.assertTrue(account.password not in str(login))
        self.assertNotEqual(login['deviceIdentifier'], account.login_payload()['deviceIdentifier'])
        with self.assertRaises(ValueError):
            account.registration_payload('')


if __name__ == '__main__':
    unittest.main()
