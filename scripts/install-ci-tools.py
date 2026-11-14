#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Install checksum-pinned fast-check binaries without executing remote scripts."""

import argparse
import hashlib
import http.client
import io
import json
import platform
import stat
import tarfile
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path
from typing import Optional


MAX_ARCHIVE_BYTES = 100_000_001


def binary_from_archive(payload: bytes, name: str, digest: str) -> bytes:
    verify_archive(payload, digest, name)
    if zipfile.is_zipfile(io.BytesIO(payload)):
        with zipfile.ZipFile(io.BytesIO(payload)) as archive:
            members = [item for item in archive.infolist() if Path(item.filename).name == name]
            if (len(members) != 1 or members[0].is_dir()
                    or stat.S_ISLNK(members[0].external_attr >> 16)
                    or members[0].file_size > 100_000_000):
                raise ValueError(f"Invalid binary member for {name}")
            return archive.read(members[0])
    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as archive:
        members = [item for item in archive.getmembers() if Path(item.name).name == name]
        if len(members) != 1 or not members[0].isfile() or members[0].size > 100_000_000:
            raise ValueError(f"Invalid binary member for {name}")
        return archive.extractfile(members[0]).read()


def verify_archive(payload: bytes, digest: str, name: str) -> None:
    if hashlib.sha256(payload).hexdigest() != digest:
        raise ValueError(f"Checksum mismatch for {name}")


def write_binary(
    destination: Path, binary: bytes, executable: bool, output_root: Path | None = None
) -> None:
    output_root = output_root or destination.parent
    parent = destination.parent
    if destination.is_symlink():
        raise ValueError(f"Refusing symlinked tool output: {destination}")
    while True:
        if parent.is_symlink():
            raise ValueError(f"Refusing symlinked tool output: {destination}")
        if parent == output_root:
            break
        if output_root not in parent.parents:
            raise ValueError(f"Tool output is outside destination directory: {destination}")
        parent = parent.parent
    destination.write_bytes(binary)
    destination.chmod(0o755 if executable else 0o644)


def read_verified_cached_archive(cache_path: Path, digest: str) -> Optional[bytes]:
    if cache_path.is_symlink():
        raise ValueError(f"Refusing symlinked cached archive: {cache_path}")
    if not cache_path.is_file():
        return None
    if cache_path.stat().st_size > MAX_ARCHIVE_BYTES:
        cache_path.unlink()
        return None
    cached = cache_path.read_bytes()
    try:
        verify_archive(cached, digest, cache_path.name)
    except ValueError:
        cache_path.unlink()
        return None
    return cached


def archive_payload(pin: dict, cache_directory: Optional[Path] = None) -> bytes:
    digest = pin["sha256"]
    if cache_directory and cache_directory.is_symlink():
        raise ValueError(f"Archive cache directory is a symlink: {cache_directory}")
    cache_path = cache_directory / f"{digest}.archive" if cache_directory else None
    if cache_path:
        cached = read_verified_cached_archive(cache_path, digest)
        if cached is not None:
            return cached

    payload = download(pin["url"])
    verify_archive(payload, digest, pin["url"])
    if cache_path:
        cache_directory.mkdir(parents=True, exist_ok=True)
        cache_path.write_bytes(payload)
    return payload


def validate_install_destinations(directory: Path, members: list[str]) -> None:
    if directory.is_symlink():
        raise ValueError(f"Refusing symlinked CI tool destination directory: {directory}")
    if directory.exists() and not directory.is_dir():
        raise ValueError(f"CI tool destination is not a directory: {directory}")
    if directory.parent.is_symlink():
        raise ValueError(f"Refusing symlinked CI tool destination parent: {directory.parent}")
    if directory.parent.parent.is_symlink():
        raise ValueError(f"Refusing symlinked ancestor for CI tool destination: {directory.parent.parent}")
    for member in members:
        destination = directory / member
        if destination.is_symlink():
            raise ValueError(f"Refusing symlinked CI tool output: {destination}")
        if destination.exists() and not destination.is_file():
            raise ValueError(f"CI tool output is not a regular file: {destination}")


DOWNLOAD_ATTEMPTS = 5
RETRYABLE_STATUS = {408, 429, 500, 502, 503, 504}


def download(url: str, sleep=time.sleep) -> bytes:
    """Fetch a pinned archive, retrying transient GitHub/CDN failures with backoff.

    The checksum check still rejects any payload that differs from the pin.
    """
    for attempt in range(1, DOWNLOAD_ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(url, timeout=60) as response:
                raw_length = getattr(response, "headers", {}).get("Content-Length")
                expected_length = int(raw_length) if raw_length is not None else None
                if expected_length is not None and expected_length > MAX_ARCHIVE_BYTES:
                    raise ValueError(f"Archive exceeds maximum size of {MAX_ARCHIVE_BYTES} bytes")
                payload = response.read(MAX_ARCHIVE_BYTES + 1)
                if len(payload) > MAX_ARCHIVE_BYTES:
                    raise ValueError(f"Archive exceeds maximum size of {MAX_ARCHIVE_BYTES} bytes")
                if expected_length is not None and len(payload) != expected_length:
                    raise urllib.error.URLError(
                        f"Incomplete download: expected {expected_length} bytes, received {len(payload)}"
                    )
                return payload
        except urllib.error.HTTPError as error:
            if error.code not in RETRYABLE_STATUS or attempt == DOWNLOAD_ATTEMPTS:
                raise
        except http.client.IncompleteRead:
            if attempt == DOWNLOAD_ATTEMPTS:
                raise
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            if attempt == DOWNLOAD_ATTEMPTS:
                raise
        sleep(2 ** attempt)
    raise AssertionError("unreachable")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, default=Path("build/ci-tools"))
    parser.add_argument("--cache-directory", type=Path)
    parser.add_argument("--include-periphery", action="store_true")
    options = parser.parse_args()
    manifest = json.loads(Path(__file__).with_name("ci-tools.json").read_text())
    host = f"{platform.system()}-{platform.machine()}"
    selected = [(name, platforms[host]) for name, platforms in manifest.items()
                if name != "periphery" or options.include_periphery]
    members = [member for name, pin in selected for member in (name, *pin.get("companions", []))]
    try:
        validate_install_destinations(options.destination, members)
    except ValueError as error:
        parser.error(str(error))
    options.destination.mkdir(parents=True, exist_ok=True)
    for name, pin in selected:
        payload = archive_payload(pin, options.cache_directory)
        for member in (name, *pin.get("companions", [])):
            binary = binary_from_archive(payload, member, pin["sha256"])
            destination = options.destination / member
            write_binary(destination, binary, member == name, options.destination)
        print(f"Installed {name} from {pin['url']} ({pin['sha256']})")


if __name__ == "__main__":
    main()
