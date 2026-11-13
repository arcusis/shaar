# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Transfer one hosted verification bundle to independent probe shards."""

import argparse
import json
import os
from pathlib import Path
import sys
import tarfile

from ci_support import file_sha256


BUNDLE_NAME = "Shaar Verification.app"
ENGINE_SHARD_COUNT = 4

# Average observed job runtimes, in seconds, across the three recent full engine
# runs. These are scheduling hints only; every requested probe iteration is
# still assigned to exactly one shard.
ENGINE_PROBE_WEIGHTS_SECONDS = {
    "baseline": 484,
    "dev-mode": 55,
    "private-multitab": 54,
    "private-window": 489,
    "quit-exit": 52,
    "session-recovery": 45,
}


def matching_pr_bundle_run_id(response: dict, pr_number: int, repository_full_name: str) -> str:
    """Select the newest successful same-repository PR run for an exact source SHA."""
    if not repository_full_name:
        return ""
    runs = [
        run
        for run in (response.get("workflow_runs") or [])
        if isinstance(run, dict)
        if run.get("conclusion") == "success"
        and (run.get("head_repository") or {}).get("full_name") == repository_full_name
        and any(pr.get("number") == pr_number
                for pr in (run.get("pull_requests") or []) if isinstance(pr, dict))
    ]
    if not runs:
        return ""
    return str(max(runs, key=lambda run: run.get("run_number", 0))["id"])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    select = subparsers.add_parser("select-pr-bundle-run")
    select.add_argument("runs_file", type=Path)
    select.add_argument("pr_number", type=int)
    select.add_argument("repository_full_name")
    arguments = parser.parse_args(argv)
    if arguments.command == "select-pr-bundle-run":
        response = json.loads(arguments.runs_file.read_text())
        print(
            matching_pr_bundle_run_id(
                response, arguments.pr_number, arguments.repository_full_name
            )
        )
        return 0
    return 2


def engine_shards(iterations: int) -> list[str]:
    if not 1 <= iterations <= 10:
        raise ValueError("Engine iterations must be between 1 and 10")
    return [f"engine-{index}" for index in range(1, ENGINE_SHARD_COUNT + 1)]


def _engine_shard_assignments(iterations: int) -> dict[str, list[tuple[str, int]]]:
    shards = engine_shards(iterations)
    assignments = {shard: [] for shard in shards}
    loads = {shard: 0 for shard in shards}
    repetitions = {
        "baseline": iterations,
        "dev-mode": iterations,
        "private-multitab": iterations,
        "private-window": max(3, iterations),
        "quit-exit": max(3, iterations),
        "session-recovery": iterations,
    }
    probes = [
        (mode, index)
        for mode in ENGINE_PROBE_WEIGHTS_SECONDS
        for index in range(1, repetitions[mode] + 1)
    ]
    mode_order = {mode: index for index, mode in enumerate(ENGINE_PROBE_WEIGHTS_SECONDS)}
    probes.sort(key=lambda probe: (
        -ENGINE_PROBE_WEIGHTS_SECONDS[probe[0]], mode_order[probe[0]], probe[1]
    ))
    for mode, index in probes:
        shard = min(shards, key=lambda candidate: (loads[candidate], candidate))
        assignments[shard].append((mode, index))
        loads[shard] += ENGINE_PROBE_WEIGHTS_SECONDS[mode]
    return assignments


def shard_modes(shard: str, iterations: int) -> list[tuple[str, range]]:
    if shard not in engine_shards(iterations):
        raise ValueError(f"Unknown engine shard: {shard}")
    assigned = _engine_shard_assignments(iterations)[shard]
    # A baseline failure must not prevent this shard from proving Dev Mode.
    assigned.sort(key=lambda item: item[0] != "dev-mode")
    return [
        (mode, range(index, index + 1))
        for mode, index in assigned
    ]


def context(root: Path) -> dict:
    pin = json.loads((root / "ThirdParty/ChromiumEngine/pin.json").read_text())
    return {"sourceTree": os.environ["CI_SOURCE_TREE"], "inputs": os.environ["CI_BUNDLE_INPUTS"],
            "toolchain": os.environ["CI_TOOLCHAIN_ID"],
            "engine": pin["sha256"]}


def validate_archive_outputs(directory: Path) -> None:
    if directory.is_symlink() or not directory.is_dir():
        raise ValueError(f"Verification archive output directory is not a regular directory: {directory}")
    for name in ("verification.tar.gz", "bundle.json"):
        path = directory / name
        if path.is_symlink():
            raise ValueError(f"Verification archive output must not be a symlink: {path}")
        if path.exists() and not path.is_file():
            raise ValueError(f"Verification archive output is not a regular file: {path}")


def archive_bundle(root: Path, directory: Path) -> None:
    validate_archive_outputs(directory)
    bundle = root / "build" / BUNDLE_NAME
    if not bundle.is_dir() or bundle.is_symlink():
        raise ValueError("Verification bundle is missing")
    archive = directory / "verification.tar.gz"
    with tarfile.open(archive, "w:gz", compresslevel=1) as output:
        output.add(bundle, arcname=BUNDLE_NAME)
    metadata = dict(context(root), sha256=file_sha256(archive))
    (directory / "bundle.json").write_text(json.dumps(metadata, indent=2) + "\n")


def validate_bundle_archive(root: Path, directory: Path) -> Path:
    metadata_path = directory / "bundle.json"
    try:
        metadata = json.loads(metadata_path.read_text())
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"Verification bundle metadata is missing or invalid: {metadata_path}: {error}") from error
    if not isinstance(metadata, dict):
        raise ValueError(f"Verification bundle metadata must be a JSON object: {metadata_path}")
    if any(metadata.get(key) != value for key, value in context(root).items()):
        raise ValueError("Verification bundle source tree, build inputs, toolchain or engine pin differs")
    archive = directory / "verification.tar.gz"
    if file_sha256(archive) != metadata.get("sha256"):
        raise ValueError("Verification bundle digest differs")
    return archive


def restore_bundle(root: Path, directory: Path) -> None:
    archive = validate_bundle_archive(root, directory)
    destination = root / "build"
    if destination.is_symlink() or not destination.is_dir():
        raise ValueError("Verification bundle destination is not a directory")
    bundle_destination = destination / BUNDLE_NAME
    if bundle_destination.exists() or bundle_destination.is_symlink():
        raise ValueError("Verification bundle destination already exists")
    with tarfile.open(archive) as source:
        for member in source.getmembers():
            if not member.name.startswith(BUNDLE_NAME + "/") and member.name != BUNDLE_NAME:
                raise ValueError("Verification archive contains an unexpected root")
        source.extractall(destination, filter="data")


if __name__ == "__main__":
    sys.exit(main())
