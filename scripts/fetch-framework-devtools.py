#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
"""Fetch pinned official CRXs and stage loopback-scoped component extensions.

Builds download the pinned CRX bytes from the framework-devtools-pins GitHub
release. The Chrome Web Store only serves the latest package, so a Web Store
fetch would break after an upstream update. `--download` talks to the Web Store
only when a maintainer is reviewing a new pin. Scorecard treats a committed
`.crx` as a binary artifact, so the bytes stay in the gitignored build cache.
"""

import argparse
import base64
from dataclasses import dataclass
import http.client
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import struct
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile


ROOT = Path(__file__).resolve().parents[1]
RELEASE_REPOSITORY = "arcusis/shaar"
RELEASE_TAG = "framework-devtools-pins"


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


def release_asset_name(name):
    return f"{name}-{PINS[name].version}.crx"


def release_asset_url(name):
    asset = release_asset_name(name)
    return f"https://github.com/{RELEASE_REPOSITORY}/releases/download/{RELEASE_TAG}/{asset}"


def web_store_url(name):
    query = urllib.parse.urlencode({
        "response": "redirect", "prodversion": "155.0.8059.84",
        "acceptformat": "crx3", "x": f"id={PINS[name].extension_id}&uc",
    })
    return "https://clients2.google.com/service/update2/crx?" + query


def read_bounded(response, name):
    data = response.read(MAX_ARCHIVE_SIZE + 1)
    if len(data) > MAX_ARCHIVE_SIZE:
        raise ValueError(f"{name}: archive exceeds size limit")
    return data


DOWNLOAD_ATTEMPTS = 3
RETRYABLE_STATUS = {408, 429, 500, 502, 503, 504}


def download_url(url, name, destination, sleep=time.sleep):
    request = urllib.request.Request(url, headers={"User-Agent": "shaar-fetch-framework-devtools"})
    for attempt in range(1, DOWNLOAD_ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                payload = read_bounded(response, name)
        except urllib.error.HTTPError as error:
            if error.code not in RETRYABLE_STATUS or attempt == DOWNLOAD_ATTEMPTS:
                raise ValueError(f"{name}: download failed from {url} ({error.code})") from error
        except (urllib.error.URLError, TimeoutError, ConnectionError, http.client.IncompleteRead) as error:
            if attempt == DOWNLOAD_ATTEMPTS:
                raise ValueError(f"{name}: download failed from {url}: {error}") from error
        else:
            destination.write_bytes(payload)
            return
        sleep(2 ** attempt)


def download_release(name, destination):
    download_url(release_asset_url(name), name, destination)


def download_web_store(name, destination):
    download_url(web_store_url(name), name, destination)


def archive_directory(explicit):
    if explicit is not None:
        return explicit
    override = os.environ.get("SHAAR_FRAMEWORK_DEVTOOLS_CACHE", "").strip()
    if override:
        return Path(override)
    return ROOT / "build" / "cache" / "framework-devtools"


def validate_archive_directory(archive_dir):
    if archive_dir.is_symlink():
        raise ValueError(f"archive cache directory must not be a symlink: {archive_dir}")
    if archive_dir.exists() and not archive_dir.is_dir():
        raise ValueError(f"archive cache path is not a directory: {archive_dir}")


def archive_matches(name, archive):
    if archive.is_symlink() or not archive.is_file():
        return False
    with archive.open("rb") as source:
        data = source.read(MAX_ARCHIVE_SIZE + 1)
    if len(data) > MAX_ARCHIVE_SIZE:
        return False
    return hashlib.sha256(data).hexdigest() == PINS[name].sha256


def install_pinned(name, archive_dir, download, source_label):
    validate_archive_directory(archive_dir)
    archive_dir.mkdir(parents=True, exist_ok=True)
    archive = archive_dir / f"{name}.crx"
    with tempfile.NamedTemporaryFile(dir=archive_dir, delete=False) as temp:
        temporary = Path(temp.name)
    try:
        download(name, temporary)
        digest = hashlib.sha256(temporary.read_bytes()).hexdigest()
        if digest != PINS[name].sha256:
            candidate = archive_dir / f"{name}.crx.candidate"
            os.replace(temporary, candidate)
            raise ValueError(
                f"{name}: {source_label} SHA-256 {digest} does not match pin "
                f"{PINS[name].sha256}. Pinned cache left unchanged. Candidate: {candidate}"
            )
        os.replace(temporary, archive)
    finally:
        temporary.unlink(missing_ok=True)
    return archive


def ensure_archive(name, archive_dir, from_web_store):
    validate_archive_directory(archive_dir)
    archive = archive_dir / f"{name}.crx"
    if not from_web_store and archive_matches(name, archive):
        return archive
    if from_web_store:
        return install_pinned(name, archive_dir, download_web_store, "Chrome Web Store package")
    print(f"Fetching {release_asset_name(name)}", file=sys.stderr)
    return install_pinned(name, archive_dir, download_release, "GitHub release asset")


def unpack(name, archive_path, destination):
    pin = PINS[name]
    with archive_path.open("rb") as source:
        archive = source.read(MAX_ARCHIVE_SIZE + 1)
    if len(archive) > MAX_ARCHIVE_SIZE:
        raise ValueError(f"{name}: archive exceeds size limit")
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
    parser.add_argument("--archive-dir", type=Path, help="cache directory for pinned CRX bytes")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--download", action="store_true",
        help="fetch the current Chrome Web Store packages to review a pin update",
    )
    args = parser.parse_args()
    try:
        output = validate_output_path(args.output)
    except ValueError as error:
        parser.error(str(error))
    archive_dir = archive_directory(args.archive_dir)
    for name in PINS:
        ensure_archive(name, archive_dir, args.download)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as staging:
        staged = Path(staging) / "FrameworkDevTools"
        staged.mkdir()
        for name in PINS:
            unpack(name, archive_dir / f"{name}.crx", staged / name)
        shutil.copytree(ROOT / "ThirdParty/FrameworkDevTools/licenses", staged / "licenses")
        if output.exists():
            shutil.rmtree(output)
        os.replace(staged, output)
    for name, pin in PINS.items():
        print(f"{name} {pin.version}: {output / name}")


def validate_output_path(path: Path) -> Path:
    absolute = path if path.is_absolute() else Path.cwd() / path
    current = Path(absolute.anchor)
    platform_symlink_aliases = {Path("/var")} if sys.platform == "darwin" else set()
    for component in absolute.parts[1:]:
        if component == "..":
            current = current.parent
            continue
        if component == ".":
            continue
        current /= component
        if current.is_symlink() and current not in platform_symlink_aliases:
            raise ValueError(f"output path must not traverse a symlink: {current}")
    output = current.resolve()
    protected_roots = (ROOT.resolve(), Path(tempfile.gettempdir()).resolve())
    if output == output.parent or any(root == output or output in root.parents for root in protected_roots):
        raise ValueError(f"refusing unsafe output directory: {path}")
    if output.exists() and not output.is_dir():
        raise ValueError(f"output exists and is not a directory: {path}")
    return output


if __name__ == "__main__":
    main()
