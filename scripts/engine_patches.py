# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Apply or verify the pinned Chromium patch series and its archive receipt."""

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
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


def git_bytes(src, *args):
    result = subprocess.run(["git", "-C", str(src), *args], capture_output=True)
    if result.returncode:
        raise PatchError(f"git {' '.join(args)} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def checked_source(src, revision):
    if run_git(src, "rev-parse", "--show-toplevel") != str(src.resolve()):
        raise PatchError("Chromium src must be the Git root")
    if run_git(src, "rev-parse", "HEAD") != revision:
        raise PatchError("Chromium src is not at the pinned revision")


def checked_patches(root, patches):
    resolved = []
    for item in patches:
        patch = root / item["file"]
        if not patch.is_file() or patch.is_symlink() or hashlib.sha256(patch.read_bytes()).hexdigest() != item["sha256"]:
            raise PatchError(f"patch missing or digest mismatch: {item['file']}")
        resolved.append((item, patch))
    return resolved


def write_receipt(output, revision, patches):
    output.parent.mkdir(parents=True, exist_ok=True)
    receipt = {"schemaVersion": 1, "chromiumRevision": revision, "patches": patches}
    temporary = output.with_name(output.name + ".partial")
    temporary.write_text(json.dumps(receipt, indent=2) + "\n")
    temporary.replace(output)


def apply(manifest, src, output):
    root, revision, patches = manifest_inputs(manifest)
    output.unlink(missing_ok=True)
    checked_source(src, revision)
    if run_git(src, "status", "--porcelain", "--untracked-files=all"):
        raise PatchError("Chromium src is not clean")
    resolved = checked_patches(root, patches)
    for item, patch in resolved:
        run_git(src, "apply", "--check", str(patch))
        run_git(src, "apply", str(patch))
        print(f"applied {item['file']}", file=sys.stderr)
    write_receipt(output, revision, patches)


def verify_tree(manifest, src, output, builder_receipt=None):
    root, revision, patches = manifest_inputs(manifest)
    output.unlink(missing_ok=True)
    checked_source(src, revision)
    src = src.resolve()
    resolved = checked_patches(root, patches)
    touched = set()
    for _, patch in resolved:
        records = git_bytes(src, "apply", "--numstat", "-z", str(patch)).split(b"\0")
        for record in records:
            if not record:
                continue
            fields = record.split(b"\t", 2)
            if len(fields) != 3:
                raise PatchError(f"cannot identify files touched by {patch.name}")
            path = os.fsdecode(fields[2])
            if (not path or path.startswith("/") or "\\" in path
                    or any(part in ("", ".", "..", ".git") for part in path.split("/"))):
                raise PatchError(f"unsafe patch path: {path}")
            touched.add(path)
    if not touched:
        raise PatchError("patch series touches no files")
    baseline = None
    if builder_receipt is not None:
        builder = json.loads(builder_receipt.read_text())
        data = json.loads(manifest.read_text())
        if (builder.get("schemaVersion") != 1
                or builder.get("chromium", {}).get("commit") != revision
                or builder.get("sourceBuildManifestSha256") != hashlib.sha256(manifest.read_bytes()).hexdigest()
                or builder.get("layerSha256") != data["layer"]["sha256"]
                or builder.get("shaarPatches") != patches
                or not isinstance(builder.get("upstreamPatchSeries"), list)
                or not builder["upstreamPatchSeries"]):
            raise PatchError("builder receipt does not match the pinned replay")
        baseline = builder.get("preShaarFiles")
        if not isinstance(baseline, dict) or set(baseline) != touched:
            raise PatchError("builder receipt has an incomplete pre-Shaar baseline")
    with tempfile.TemporaryDirectory(prefix="shaar-patch-verify-") as temporary:
        scratch = Path(temporary)
        run_git(scratch, "init", "-q")
        original_states = {}
        for name in sorted(touched):
            source = src / name
            for parent in source.parents:
                if parent == src or parent == src.parent:
                    break
                if parent.is_symlink():
                    raise PatchError(f"source path has symlink parent: {name}")
            destination = scratch / name
            if source.is_symlink():
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.symlink_to(os.readlink(source))
                original_states[name] = ("symlink", os.readlink(source))
            elif source.is_file():
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, destination)
                original_states[name] = ("file", stat.S_IMODE(source.stat().st_mode),
                                         hashlib.sha256(destination.read_bytes()).hexdigest())
            elif source.exists():
                raise PatchError(f"source path is not a file: {name}")
            else:
                original_states[name] = ("missing",)
        for item, patch in reversed(resolved):
            run_git(scratch, "apply", "--check", "--reverse", str(patch))
            run_git(scratch, "apply", "--reverse", str(patch))
            print(f"reversed {item['file']}", file=sys.stderr)
        for name in sorted(touched):
            if baseline is not None:
                target = scratch / name
                expected_state = baseline[name]
                if not isinstance(expected_state, dict):
                    raise PatchError(f"invalid pre-Shaar baseline: {name}")
                if expected_state.get("kind") == "missing":
                    matches = not target.exists() and not target.is_symlink()
                elif expected_state.get("kind") == "symlink":
                    matches = target.is_symlink() and os.readlink(target) == expected_state.get("target")
                elif expected_state.get("kind") == "file":
                    matches = (target.is_file() and not target.is_symlink()
                               and hashlib.sha256(target.read_bytes()).hexdigest() == expected_state.get("sha256")
                               and bool(target.stat().st_mode & stat.S_IXUSR) == expected_state.get("executable"))
                else:
                    matches = False
                if not matches:
                    raise PatchError(f"unwound tree differs from builder baseline: {name}")
            else:
                expected = git_bytes(src, "ls-tree", "-z", revision, "--", name)
                target = scratch / name
                if not expected:
                    if target.exists() or target.is_symlink():
                        raise PatchError(f"unwound tree differs from upstream: {name}")
                else:
                    if expected.count(b"\0") != 1:
                        raise PatchError(f"ambiguous upstream path: {name}")
                    metadata = expected.split(b"\t", 1)[0].split()
                    if len(metadata) != 3 or metadata[1] != b"blob":
                        raise PatchError(f"unsupported upstream path: {name}")
                    upstream = git_bytes(src, "show", f"{revision}:{name}")
                    mode = metadata[0]
                    if mode == b"120000":
                        if not target.is_symlink() or os.fsencode(os.readlink(target)) != upstream:
                            raise PatchError(f"unwound tree differs from upstream: {name}")
                    elif mode in (b"100644", b"100755"):
                        if (not target.is_file() or target.is_symlink()
                                or target.read_bytes() != upstream
                                or bool(target.stat().st_mode & stat.S_IXUSR) != (mode == b"100755")):
                            raise PatchError(f"unwound tree differs from upstream: {name}")
                    else:
                        raise PatchError(f"unsupported upstream mode: {name}")
            source = src / name
            state = original_states[name]
            if state[0] == "symlink":
                unchanged = source.is_symlink() and os.readlink(source) == state[1]
            elif state[0] == "file":
                unchanged = (source.is_file() and not source.is_symlink()
                             and stat.S_IMODE(source.stat().st_mode) == state[1]
                             and hashlib.sha256(source.read_bytes()).hexdigest() == state[2])
            else:
                unchanged = not source.exists() and not source.is_symlink()
            if not unchanged:
                raise PatchError(f"source changed during verification: {name}")
    checked_source(src, revision)
    write_receipt(output, revision, patches)


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
    modes.add_argument("--verify-tree", type=Path, metavar="CHROMIUM_SRC")
    modes.add_argument("--verify-archive", type=Path, metavar="ARCHIVE")
    modes.add_argument("--verify-receipt", type=Path, metavar="RECEIPT")
    parser.add_argument("--output", type=Path, default=Path("build/ShaarEngineSource") / RECEIPT)
    parser.add_argument("--builder-receipt", type=Path,
                        help="pinned 157 builder replay receipt with the pre-Shaar baseline")
    args = parser.parse_args()
    try:
        if args.builder_receipt and not args.verify_tree:
            raise PatchError("--builder-receipt requires --verify-tree")
        if args.apply:
            apply(args.manifest, args.apply, args.output)
        elif args.verify_tree:
            verify_tree(args.manifest, args.verify_tree, args.output, args.builder_receipt)
        elif args.verify_archive:
            verify_archive(args.manifest, args.verify_archive)
        else:
            validate_receipt(args.verify_receipt.read_bytes(), args.manifest)
    except (PatchError, OSError, KeyError, ValueError, TypeError) as error:
        parser.exit(1, f"engine patches: {error}\n")


if __name__ == "__main__":
    main()
