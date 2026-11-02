#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Install checksum-pinned fast-check binaries without executing remote scripts."""

import argparse
import hashlib
import io
import json
import platform
import tarfile
import urllib.request
import zipfile
from pathlib import Path


def binary_from_archive(payload: bytes, name: str, digest: str) -> bytes:
    if hashlib.sha256(payload).hexdigest() != digest:
        raise ValueError(f"Checksum mismatch for {name}")
    if zipfile.is_zipfile(io.BytesIO(payload)):
        with zipfile.ZipFile(io.BytesIO(payload)) as archive:
            members = [item for item in archive.infolist() if Path(item.filename).name == name]
            if len(members) != 1 or members[0].is_dir() or members[0].file_size > 100_000_000:
                raise ValueError(f"Invalid binary member for {name}")
            return archive.read(members[0])
    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as archive:
        members = [item for item in archive.getmembers() if Path(item.name).name == name]
        if len(members) != 1 or not members[0].isfile() or members[0].size > 100_000_000:
            raise ValueError(f"Invalid binary member for {name}")
        return archive.extractfile(members[0]).read()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, default=Path("build/ci-tools"))
    parser.add_argument("--include-periphery", action="store_true")
    options = parser.parse_args()
    manifest = json.loads(Path(__file__).with_name("ci-tools.json").read_text())
    host = f"{platform.system()}-{platform.machine()}"
    options.destination.mkdir(parents=True, exist_ok=True)
    for name, platforms in manifest.items():
        if name == "periphery" and not options.include_periphery:
            continue
        pin = platforms[host]
        with urllib.request.urlopen(pin["url"], timeout=60) as response:
            payload = response.read(100_000_001)
        for member in (name, *pin.get("companions", [])):
            binary = binary_from_archive(payload, member, pin["sha256"])
            destination = options.destination / member
            destination.write_bytes(binary)
            destination.chmod(0o755 if member == name else 0o644)
        print(f"Installed {name} from {pin['url']} ({pin['sha256']})")


if __name__ == "__main__":
    main()
