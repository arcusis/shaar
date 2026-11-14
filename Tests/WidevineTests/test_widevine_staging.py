# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Prove that CRX3 verification accepts a signed payload and rejects tampering."""

import hashlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[2] / "scripts/stage-widevine-cdm.py"
SPEC = importlib.util.spec_from_file_location("stage_widevine_cdm", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def varint(number):
    result = bytearray()
    while number > 127:
        result.append((number & 127) | 128)
        number >>= 7
    result.append(number)
    return bytes(result)


def field(number, value):
    return varint(number << 3 | 2) + varint(len(value)) + value


class WidevineSignatureTests(unittest.TestCase):
    def test_omaha_response_requires_full_package_hash_and_google_url(self):
        response = {"response": {"protocol": "3.1", "app": [{
            "appid": MODULE.COMPONENT_ID, "updatecheck": {
                "status": "ok", "urls": {"url": [
                    {"codebase": "https://redirector.gvt1.com/edgedl/widevine/"}]},
                "manifest": {"version": "4.10.1.2", "packages": {"package": [{
                    "name": "widevine.crx3", "size": 32, "hash_sha256": "a" * 64}]}}}}]}}
        data = b")]}\'\n" + json.dumps(response).encode()
        with patch.object(MODULE.urllib.request, "urlopen", return_value=io.BytesIO(data)):
            self.assertEqual(MODULE.component_url(), (
                "https://redirector.gvt1.com/edgedl/widevine/widevine.crx3",
                "4.10.1.2", "a" * 64, 32))
        response["response"]["app"][0]["updatecheck"]["manifest"]["packages"]["package"][0]["name"] = "../wrong.crx3"
        data = b")]}\'\n" + json.dumps(response).encode()
        with patch.object(MODULE.urllib.request, "urlopen", return_value=io.BytesIO(data)):
            with self.assertRaisesRegex(ValueError, "package name"):
                MODULE.component_url()

    def test_signed_crx3_and_mutated_payload(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            private = root / "key.pem"
            public = root / "key.der"
            subprocess.run(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt",
                            "rsa_keygen_bits:2048", "-out", str(private)],
                           check=True, capture_output=True)
            subprocess.run(["openssl", "pkey", "-in", str(private), "-pubout",
                            "-outform", "DER", "-out", str(public)],
                           check=True, capture_output=True)
            public_bytes = public.read_bytes()
            digest = hashlib.sha256(public_bytes).digest()
            component_id = "".join(chr(97 + nibble) for byte in digest[:16]
                                   for nibble in (byte >> 4, byte & 15))
            signed_header = field(1, digest[:16])
            payload = b"PK\x03\x04signed test payload"
            signed_data = (b"CRX3 SignedData\0" + struct.pack("<I", len(signed_header))
                           + signed_header + payload)
            data_path = root / "signed-data"
            signature_path = root / "signature"
            data_path.write_bytes(signed_data)
            subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(private),
                            "-out", str(signature_path), str(data_path)],
                           check=True, capture_output=True)
            proof = field(1, public_bytes) + field(2, signature_path.read_bytes())
            header = field(2, proof) + field(10000, signed_header)
            crx = b"Cr24" + struct.pack("<II", 3, len(header)) + header + payload
            self.assertEqual(MODULE.authenticated_zip(crx, component_id, digest), payload)
            with self.assertRaisesRegex(ValueError, "signature"):
                MODULE.authenticated_zip(crx[:-1] + b"X", component_id, digest)
            with self.assertRaisesRegex(ValueError, "signature"):
                MODULE.authenticated_zip(crx, component_id, bytes(32))


if __name__ == "__main__":
    unittest.main()
