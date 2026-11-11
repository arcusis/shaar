# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Apply the pinned Chromium patch series and verify its archive receipt."""

import argparse
import hashlib
import json
import re
import subprocess
import sys
import tarfile
from pathlib import Path


RECEIPT = "applied-patches.json"


class PatchError(Exception):
    pass


def manifest_inputs(manifest):
    data = json.loads(manifest.read_text())
    revision = data["chromium"]["commit"]
    patches = data["patches"]
    if not re.fullmatch(r"[0-9a-f]{40}", revision) or not isinstance(patches, list) or not patches:
        raise PatchError("invalid Chromium revision or empty patch series")
    root = manifest.resolve().parents[2]
    expected = []
    for item in patches:
        name, digest = item["file"], item["sha256"]
        if (not isinstance(name, str) or not re.fullmatch(
                r"ThirdParty/ChromiumEngine/patches/[0-9]{4}-[a-z0-9-]+\.patch", name)
                or not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest)):
            raise PatchError("invalid patch manifest entry")
        expected.append({"file": name, "sha256": digest})
    if len({entry["file"] for entry in expected}) != len(expected):
        raise PatchError("duplicate patch in manifest")
    return root, revision, expected


def run_git(src, *args):
    result = subprocess.run(["git", "-C", str(src), *args], capture_output=True, text=True)
    if result.returncode:
        raise PatchError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def apply(manifest, src, output):
    root, revision, patches = manifest_inputs(manifest)
    output.unlink(missing_ok=True)
    if run_git(src, "rev-parse", "--show-toplevel") != str(src.resolve()):
        raise PatchError("Chromium src must be the Git root")
    if run_git(src, "rev-parse", "HEAD") != revision:
        raise PatchError("Chromium src is not at the pinned revision")
    if run_git(src, "status", "--porcelain", "--untracked-files=all"):
        raise PatchError("Chromium src is not clean")
    resolved = []
    for item in patches:
        patch = root / item["file"]
        if not patch.is_file() or patch.is_symlink() or hashlib.sha256(patch.read_bytes()).hexdigest() != item["sha256"]:
            raise PatchError(f"patch missing or digest mismatch: {item['file']}")
        resolved.append((item, patch))
    output.parent.mkdir(parents=True, exist_ok=True)
    for item, patch in resolved:
        run_git(src, "apply", "--check", str(patch))
        run_git(src, "apply", str(patch))
        print(f"applied {item['file']}", file=sys.stderr)
    receipt = {"schemaVersion": 1, "chromiumRevision": revision, "patches": patches}
    temporary = output.with_name(output.name + ".partial")
    temporary.write_text(json.dumps(receipt, indent=2) + "\n")
    temporary.replace(output)


def validate_receipt(raw, manifest):
    _, revision, patches = manifest_inputs(manifest)
    try:
        receipt = json.loads(raw)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise PatchError("patch receipt malformed") from error
    if receipt != {"schemaVersion": 1, "chromiumRevision": revision, "patches": patches}:
        raise PatchError("patch receipt does not match full pinned series")


def verify_archive(manifest, archive):
    try:
        with tarfile.open(archive, "r:xz") as source:
            matches = [member for member in source if member.name == RECEIPT]
            if len(matches) != 1 or not matches[0].isfile() or matches[0].size > 32768:
                raise PatchError("archive has no unique regular patch receipt")
            stream = source.extractfile(matches[0])
            if stream is None:
                raise PatchError("archive patch receipt cannot be read")
            validate_receipt(stream.read(), manifest)
    except (OSError, tarfile.TarError, EOFError) as error:
        raise PatchError("archive patch receipt cannot be read") from error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=Path(__file__).resolve().parents[1] /
                        "ThirdParty/ChromiumEngine/source-build.json")
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--apply", type=Path, metavar="CHROMIUM_SRC")
    modes.add_argument("--verify-archive", type=Path, metavar="ARCHIVE")
    modes.add_argument("--verify-receipt", type=Path, metavar="RECEIPT")
    parser.add_argument("--output", type=Path, default=Path("build/ShaarEngineSource") / RECEIPT)
    args = parser.parse_args()
    try:
        if args.apply:
            apply(args.manifest, args.apply, args.output)
        elif args.verify_archive:
            verify_archive(args.manifest, args.verify_archive)
        else:
            validate_receipt(args.verify_receipt.read_bytes(), args.manifest)
    except (PatchError, OSError, KeyError, ValueError, TypeError) as error:
        parser.exit(1, f"engine patches: {error}\n")


if __name__ == "__main__":
    main()
