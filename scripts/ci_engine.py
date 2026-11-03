# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Transfer one hosted verification bundle to independent probe shards."""

import json
import os
from pathlib import Path
import tarfile

from ci_support import file_sha256


BUNDLE_NAME = "Shaar Verification.app"


def engine_shards(iterations: int) -> list[str]:
    if not 1 <= iterations <= 10:
        raise ValueError("Engine iterations must be between 1 and 10")
    return ["baseline-lifecycle", "private-multitab",
            *(f"private-window-{index}" for index in range(1, max(3, iterations) + 1))]


def shard_modes(shard: str, iterations: int) -> list[tuple[str, range]]:
    if shard not in engine_shards(iterations):
        raise ValueError(f"Unknown engine shard: {shard}")
    if shard == "baseline-lifecycle":
        return [("baseline", range(1, iterations + 1)), ("quit-exit", range(1, max(3, iterations) + 1)),
                ("session-recovery", range(1, iterations + 1))]
    if shard == "private-multitab":
        return [("private-multitab", range(1, iterations + 1))]
    index = int(shard.rsplit("-", 1)[1])
    return [("private-window", range(index, index + 1))]


def context(root: Path) -> dict:
    pin = json.loads((root / "ThirdParty/ArdiaCore/pin.json").read_text())
    return {"sourceTree": os.environ["CI_SOURCE_TREE"], "toolchain": os.environ["CI_TOOLCHAIN_ID"],
            "engine": pin["sha256"]}


def archive_bundle(root: Path, directory: Path) -> None:
    bundle = root / "build" / BUNDLE_NAME
    if not bundle.is_dir() or bundle.is_symlink():
        raise ValueError("Verification bundle is missing")
    archive = directory / "verification.tar.gz"
    with tarfile.open(archive, "w:gz", compresslevel=1) as output:
        output.add(bundle, arcname=BUNDLE_NAME)
    metadata = dict(context(root), sha256=file_sha256(archive))
    (directory / "bundle.json").write_text(json.dumps(metadata, indent=2) + "\n")


def validate_bundle_archive(root: Path, directory: Path) -> Path:
    metadata = json.loads((directory / "bundle.json").read_text())
    if any(metadata.get(key) != value for key, value in context(root).items()):
        raise ValueError("Verification bundle source tree, toolchain or engine pin differs")
    archive = directory / "verification.tar.gz"
    if file_sha256(archive) != metadata.get("sha256"):
        raise ValueError("Verification bundle digest differs")
    return archive


def restore_bundle(root: Path, directory: Path) -> None:
    archive = validate_bundle_archive(root, directory)
    destination = root / "build"
    if (destination / BUNDLE_NAME).exists():
        raise ValueError("Verification bundle destination already exists")
    with tarfile.open(archive) as source:
        for member in source.getmembers():
            if not member.name.startswith(BUNDLE_NAME + "/") and member.name != BUNDLE_NAME:
                raise ValueError("Verification archive contains an unexpected root")
        source.extractall(destination, filter="data")
