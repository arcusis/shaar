#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Opt-in, package-time install of Google's signed mac-arm64 Widevine component.

The component is never stored in the source tree. CRX3 authentication binds the
downloaded ZIP bytes to Google's published Widevine component ID; the installed
library retains its own Google code signature.
"""

import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile


COMPONENT_ID = "oimompecagnajdejgnnjijobebaeigek"
# Chromium's widevine_cdm_component_installer.cc pins this complete SHA-256,
# which also determines the CRX ID (first 16 bytes encoded a-p).
COMPONENT_KEY_SHA256 = bytes.fromhex(
    "e8cecf4206d093496dd989e14104864a8fbd8612b9589bfb4fbb1ba9d38537ef")
UPDATE_URL = "https://update.googleapis.com/service/update2/json"
MAX_SIZE = 100 * 1024 * 1024


def fields(data: bytes):
    position = 0
    while position < len(data):
        key, position = varint(data, position)
        number, wire = key >> 3, key & 7
        if wire == 0:
            value, position = varint(data, position)
        elif wire == 2:
            size, position = varint(data, position)
            if size > len(data) - position:
                raise ValueError("truncated CRX3 field")
            value = data[position:position + size]
            position += size
        elif wire in (1, 5):
            size = 8 if wire == 1 else 4
            if size > len(data) - position:
                raise ValueError("truncated CRX3 field")
            value = data[position:position + size]
            position += size
        else:
            raise ValueError("unsupported CRX3 field")
        yield number, wire, value


def varint(data: bytes, position: int):
    value = 0
    for shift in range(0, 70, 7):
        if position >= len(data):
            raise ValueError("truncated CRX3 varint")
        octet = data[position]
        position += 1
        value |= (octet & 0x7f) << shift
        if not octet & 0x80:
            return value, position
    raise ValueError("oversized CRX3 varint")


def one(data: bytes, number: int) -> bytes:
    matches = [value for n, wire, value in fields(data) if n == number and wire == 2]
    if len(matches) != 1:
        raise ValueError(f"CRX3 field {number} missing or repeated")
    return matches[0]


def authenticated_zip(
    crx: bytes, component_id: str = COMPONENT_ID,
    key_sha256: bytes = COMPONENT_KEY_SHA256
) -> bytes:
    if len(crx) < 12 or crx[:4] != b"Cr24" or struct.unpack_from("<I", crx, 4)[0] != 3:
        raise ValueError("Google did not return a CRX3 component")
    header_size = struct.unpack_from("<I", crx, 8)[0]
    if header_size > 1024 * 1024 or 12 + header_size >= len(crx):
        raise ValueError("invalid CRX3 header length")
    header = crx[12:12 + header_size]
    signed_header = one(header, 10000)
    crx_id = one(signed_header, 1)
    if len(crx_id) != 16 or "".join(chr(97 + nibble) for byte in crx_id
                                      for nibble in (byte >> 4, byte & 15)) != component_id:
        raise ValueError("CRX3 signed component ID is not Widevine")
    payload = crx[12 + header_size:]
    signed_data = b"CRX3 SignedData\0" + struct.pack("<I", len(signed_header)) + signed_header + payload
    proofs = [(number, value) for number, wire, value in fields(header)
              if number in (2, 3) and wire == 2]
    if not proofs:
        raise ValueError("CRX3 has no signature proof")
    for _, proof in proofs:
        try:
            public_key, signature = one(proof, 1), one(proof, 2)
        except ValueError:
            continue
        digest = hashlib.sha256(public_key).digest()[:16]
        if hashlib.sha256(public_key).digest() != key_sha256 or digest != crx_id:
            continue
        with tempfile.TemporaryDirectory(prefix="shaar-crx-proof-") as directory:
            root = Path(directory)
            (root / "key.der").write_bytes(public_key)
            (root / "signature").write_bytes(signature)
            (root / "signed-data").write_bytes(signed_data)
            key = subprocess.run(["openssl", "pkey", "-pubin", "-inform", "DER", "-in",
                                  str(root / "key.der"), "-out", str(root / "key.pem")],
                                 capture_output=True)
            if key.returncode:
                continue
            valid = subprocess.run(["openssl", "dgst", "-sha256", "-verify",
                                    str(root / "key.pem"), "-signature", str(root / "signature"),
                                    str(root / "signed-data")], capture_output=True)
            if valid.returncode == 0:
                return payload
    raise ValueError("Widevine CRX3 signature or public-key hash invalid")


def get(url: str) -> bytes:
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "Shaar-CDM-Packager/1"}),
                                timeout=60) as response:
        result = response.read(MAX_SIZE + 1)
    if len(result) > MAX_SIZE:
        raise ValueError("component download exceeds size limit")
    return result


def component_url() -> tuple[str, str, str, int]:
    request = {"request": {
        "@os": "mac", "@updater": "Shaar", "acceptformat": "crx3",
        "protocol": "3.1", "updaterversion": "157.0.8103.51",
        "os": {"platform": "mac", "arch": "arm64", "version": platform.mac_ver()[0]},
        "app": [{"appid": COMPONENT_ID, "version": "0.0.0.0", "updatecheck": {}}],
    }}
    body = json.dumps(request, separators=(",", ":")).encode()
    http_request = urllib.request.Request(
        UPDATE_URL, data=body,
        headers={"Content-Type": "application/json", "X-Goog-Update-AppId": COMPONENT_ID,
                 "X-Goog-Update-Interactivity": "fg",
                 "X-Goog-Update-Updater": "Shaar-157.0.8103.51"})
    with urllib.request.urlopen(http_request, timeout=60) as response:
        raw = response.read(1024 * 1024 + 1)
    if len(raw) > 1024 * 1024:
        raise ValueError("oversized Google component update response")
    if raw.startswith(b")]}\'\n"):
        raw = raw[5:]
    response = json.loads(raw)["response"]
    apps = response.get("app", [])
    if response.get("protocol") != "3.1" or len(apps) != 1 or apps[0].get("appid") != COMPONENT_ID:
        raise ValueError("Google component update response omitted Widevine")
    update = apps[0].get("updatecheck", {})
    if update.get("status") != "ok":
        raise ValueError(f"Google component update returned {update.get('status')}; no CDM was staged")
    manifest = update.get("manifest", {})
    version = manifest.get("version", "")
    packages = manifest.get("packages", {}).get("package", [])
    urls = update.get("urls", {}).get("url", [])
    if len(packages) != 1 or not urls:
        raise ValueError("Widevine update has no single full CRX3 package")
    package = packages[0]
    name = package.get("name", "")
    if not name or Path(name).name != name or name in (".", ".."):
        raise ValueError("unsafe component package name")
    codebases = [item.get("codebase", "") for item in urls if item.get("codebase")]
    if not codebases:
        raise ValueError("Widevine update has no full download URL")
    url = codebases[0] + name
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or not (parsed.hostname == "google.com" or
                                            parsed.hostname.endswith(".google.com") or
                                            parsed.hostname == "gvt1.com" or
                                            parsed.hostname.endswith(".gvt1.com") or
                                            parsed.hostname == "googleapis.com" or
                                            parsed.hostname.endswith(".googleapis.com")):
        raise ValueError("component URL is outside Google HTTPS hosts")
    if not version or not all(part.isdigit() for part in version.split(".")):
        raise ValueError("invalid component version")
    server_hash = package.get("hash_sha256", "")
    if len(server_hash) != 64 or any(char not in "0123456789abcdef" for char in server_hash):
        raise ValueError("invalid component response SHA256")
    size = package.get("size")
    if not isinstance(size, int) or size <= 0 or size > MAX_SIZE:
        raise ValueError("invalid component package size")
    return url, version, server_hash, size


def stage(framework: Path) -> None:
    if os.uname().machine != "arm64":
        raise ValueError("Widevine staging requires mac-arm64")
    libraries = framework / "Versions/Current/Libraries"
    if not libraries.is_dir():
        raise ValueError("Chromium framework Libraries directory is missing")
    destination = libraries / "WidevineCdm"
    if destination.exists() or destination.is_symlink():
        raise ValueError("WidevineCdm is already staged")
    url, version, server_hash, expected_size = component_url()
    crx = get(url)
    if len(crx) != expected_size or hashlib.sha256(crx).hexdigest() != server_hash:
        raise ValueError("Google component response SHA256 mismatch")
    payload = authenticated_zip(crx)
    with tempfile.TemporaryDirectory(prefix="shaar-widevine-") as temporary:
        root = Path(temporary)
        archive = root / "component.zip"
        archive.write_bytes(payload)
        staged = root / "WidevineCdm"
        staged.mkdir()
        with zipfile.ZipFile(archive) as source:
            if sum(member.file_size for member in source.infolist()) > MAX_SIZE:
                raise ValueError("Widevine component expands beyond size limit")
            for member in source.infolist():
                path = Path(member.filename)
                if (path.is_absolute() or ".." in path.parts or member.file_size > MAX_SIZE
                        or (member.external_attr >> 16) & 0o170000 == 0o120000):
                    raise ValueError("unsafe Widevine component archive")
                target = staged / path
                if member.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with source.open(member) as input_file, target.open("wb") as output_file:
                        shutil.copyfileobj(input_file, output_file)
        manifest = staged / "manifest.json"
        binary = staged / "_platform_specific/mac_arm64/libwidevinecdm.dylib"
        if not manifest.is_file() or not binary.is_file():
            raise ValueError("Widevine component lacks mac-arm64 library or manifest")
        metadata = json.loads(manifest.read_text())
        if (metadata.get("version") != version or metadata.get("name") != "WidevineCdm"
                or metadata.get("description") != "Widevine Content Decryption Module"):
            raise ValueError("Widevine manifest does not match component response")
        minimum = metadata.get("minimum_chrome_version", "")
        if (not minimum or not all(part.isdigit() for part in minimum.split("."))
                or tuple(map(int, minimum.split("."))) > (157, 0, 8103, 51)):
            raise ValueError("Widevine requires a newer Chromium engine")
        architecture = subprocess.run(["lipo", "-archs", str(binary)],
                                      capture_output=True, text=True)
        if architecture.returncode or "arm64" not in architecture.stdout.split():
            raise ValueError("Widevine library is not mac-arm64")
        signature = subprocess.run(["codesign", "--verify", "--strict", "--verbose=2", str(binary)],
                                   capture_output=True, text=True)
        if signature.returncode:
            raise ValueError(f"Google CDM code signature invalid: {signature.stderr.strip()}")
        identity = subprocess.run(["codesign", "-dv", "--verbose=4", str(binary)],
                                  capture_output=True, text=True)
        if "Authority=Developer ID Application: Google LLC" not in identity.stderr:
            raise ValueError("CDM library is not signed by Google LLC")
        shutil.copytree(staged, destination)
        print(f"Staged authenticated Widevine {version} ({hashlib.sha256(crx).hexdigest()}) at {destination}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("framework", type=Path)
    arguments = parser.parse_args()
    try:
        stage(arguments.framework)
    except (ValueError, OSError, urllib.error.URLError) as error:
        parser.exit(1, f"Widevine staging failed: {error}\n")
