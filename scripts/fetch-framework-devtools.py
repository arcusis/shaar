#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
"""Fetch pinned official CRXs and stage loopback-scoped component extensions."""

import argparse
import base64
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import struct
import tempfile
import urllib.parse
import urllib.request
import zipfile


ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class PackagePin:
    extension_id: str
    version: str
    sha256: str
    devtools_page: str
    page_script: str


PINS = {
    "react": PackagePin(
        "fmkadmapgofadopljbjfkapdkoienihi", "8.0.0",
        "d92e1122a16362cc5510927068a5b1a8d50b43e1f3be25c3117f7c005807b302",
        "main.html", "./build/main.js",
    ),
    "vue": PackagePin(
        "nhdogjmejiglipccpnnnanhbledajbpd", "7.7.7",
        "bf565c23fd9e2c074ed47144d0504336f787e5f105388f73c62846dee92f0124",
        "pages/devtools-background.html", "../dist/devtools-background.js",
    ),
    "angular": PackagePin(
        "ienfalfjdbdpebioblfackkekamfmbnh", "1.22.1",
        "2407ac2707367e71ee8a01c162d75465bc1633ddaa59f95b69d2f964a705afff",
        "devtools.html", "devtools_bundle.js",
    ),
}
LOCAL_MATCHES = ["http://localhost/*", "https://localhost/*", "http://127.0.0.1/*", "https://127.0.0.1/*"]
MAX_ARCHIVE_SIZE = 16 * 1024 * 1024
MAX_UNPACKED_SIZE = 64 * 1024 * 1024


def read_varint(data, offset):
    value = 0
    shift = 0
    while offset < len(data):
        byte = data[offset]
        offset += 1
        value |= (byte & 0x7f) << shift
        if byte < 128:
            return value, offset
        shift += 7
    raise ValueError("truncated CRX header")


def protobuf_fields(data):
    offset = 0
    while offset < len(data):
        field, offset = read_varint(data, offset)
        if field & 7 != 2:
            raise ValueError("unexpected CRX header field")
        length, offset = read_varint(data, offset)
        end = offset + length
        if end > len(data):
            raise ValueError("truncated CRX header field")
        yield field >> 3, data[offset:end]
        offset = end


def public_key_for_id(archive, expected_id):
    if archive[:8] != b"Cr24\x03\x00\x00\x00":
        raise ValueError("expected CRX3 archive")
    header_size = struct.unpack_from("<I", archive, 8)[0]
    if header_size > 64 * 1024 or 12 + header_size >= len(archive):
        raise ValueError("invalid CRX3 header size")
    for number, proof in protobuf_fields(archive[12:12 + header_size]):
        if number not in (2, 3):
            continue
        for child, key in protobuf_fields(proof):
            if child != 1:
                continue
            digest = hashlib.sha256(key).digest()[:16]
            extension_id = "".join(chr(97 + nibble) for byte in digest for nibble in (byte >> 4, byte & 15))
            if extension_id == expected_id:
                return base64.b64encode(key).decode("ascii")
    raise ValueError("CRX public key does not match expected extension ID")


def download(name, destination):
    extension_id = PINS[name].extension_id
    query = urllib.parse.urlencode({
        "response": "redirect", "prodversion": "155.0.8059.84",
        "acceptformat": "crx3", "x": f"id={extension_id}&uc",
    })
    url = "https://clients2.google.com/service/update2/crx?" + query
    with urllib.request.urlopen(url, timeout=60) as response:
        data = response.read(MAX_ARCHIVE_SIZE + 1)
    if len(data) > MAX_ARCHIVE_SIZE:
        raise ValueError(f"{name}: archive exceeds size limit")
    destination.write_bytes(data)


def unpack(name, archive_path, destination):
    pin = PINS[name]
    archive = archive_path.read_bytes()
    if hashlib.sha256(archive).hexdigest() != pin.sha256:
        raise ValueError(f"{name}: CRX SHA-256 mismatch; upstream version may have changed")
    public_key = public_key_for_id(archive, pin.extension_id)
    with zipfile.ZipFile(archive_path) as source:
        entries = source.infolist()
        if sum(entry.file_size for entry in entries) > MAX_UNPACKED_SIZE:
            raise ValueError(f"{name}: unpacked extension exceeds size limit")
        for entry in entries:
            path = PurePosixPath(entry.filename)
            if path.is_absolute() or ".." in path.parts or not path.parts or entry.filename.startswith("__MACOSX/"):
                raise ValueError(f"{name}: unsafe archive path")
            if (entry.external_attr >> 16) & 0o170000 == 0o120000:
                raise ValueError(f"{name}: symlink in archive")
            target = destination.joinpath(*path.parts)
            if entry.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with source.open(entry) as src, target.open("wb") as dst:
                    shutil.copyfileobj(src, dst)

    manifest_path = destination / "manifest.json"
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("version") != pin.version or manifest.get("devtools_page") != pin.devtools_page:
        raise ValueError(f"{name}: unexpected version or DevTools entry")
    if manifest.get("manifest_version") != 3:
        raise ValueError(f"{name}: expected Manifest V3")
    manifest.pop("update_url", None)
    manifest["key"] = public_key
    manifest["host_permissions"] = LOCAL_MATCHES
    for script in manifest.get("content_scripts", []):
        script["matches"] = LOCAL_MATCHES
    for resource in manifest.get("web_accessible_resources", []):
        resource["matches"] = LOCAL_MATCHES
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    page_path = destination / pin.devtools_page
    page = page_path.read_text()
    original_tag = f'<script src="{pin.page_script}"></script>'
    if page.count(original_tag) != 1:
        raise ValueError(f"{name}: unexpected DevTools page script")
    page_path.write_text(page.replace(original_tag, '<script src="shaar-devtools.js"></script>'))
    (page_path.parent / "shaar-devtools.js").write_bytes(
        (ROOT / "Resources/FrameworkDevTools/shaar-devtools.js").read_bytes().replace(
            b"__UPSTREAM_SCRIPT__", pin.page_script.encode("ascii")
        )
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive-dir", type=Path, default=ROOT / "ThirdParty/FrameworkDevTools/archives")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--download", action="store_true", help="refresh archives from the official Chrome Web Store")
    args = parser.parse_args()
    args.archive_dir.mkdir(parents=True, exist_ok=True)
    for name in PINS:
        archive = args.archive_dir / f"{name}.crx"
        if args.download:
            with tempfile.NamedTemporaryFile(dir=args.archive_dir, delete=False) as temp:
                temporary = Path(temp.name)
            try:
                download(name, temporary)
                if hashlib.sha256(temporary.read_bytes()).hexdigest() != PINS[name].sha256:
                    raise ValueError(f"{name}: fetched CRX differs from pinned SHA-256")
                os.replace(temporary, archive)
            finally:
                temporary.unlink(missing_ok=True)
        if not archive.is_file():
            raise FileNotFoundError(f"{archive}: run this script with --download")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=args.output.parent) as staging:
        staged = Path(staging) / "FrameworkDevTools"
        staged.mkdir()
        for name in PINS:
            unpack(name, args.archive_dir / f"{name}.crx", staged / name)
        shutil.copytree(ROOT / "ThirdParty/FrameworkDevTools/licenses", staged / "licenses")
        if args.output.exists():
            shutil.rmtree(args.output)
        os.replace(staged, args.output)
    for name, pin in PINS.items():
        print(f"{name} {pin.version}: {args.output / name}")


if __name__ == "__main__":
    main()
