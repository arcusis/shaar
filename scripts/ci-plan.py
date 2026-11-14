#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Select native, website and Swift analysis from immutable, conservative diffs."""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

from ci_support import output_file


def documentation_only(paths: list[str]) -> bool:
    return bool(paths) and all(
        path.startswith("Notebook/")
        or "/" not in path and path.endswith(".md")
        or len(path.split("/")) == 3
        and path.startswith("ThirdParty/")
        and path.endswith("/README.md")
        for path in paths
    )


def decode_changed_paths(output: bytes) -> list[str]:
    return [os.fsdecode(path) for path in output.split(b"\0") if path]


def website_path(path: str) -> bool:
    return (path.startswith(("website/", ".github/assets/")) or path == "Branding/shaar-logo.svg"
            or path in {"LICENSE", "NOTICE", "THIRD_PARTY_NOTICES.md", "scripts/check-license-headers.py"}
            or path.startswith("Tests/LicenseHeaderTests/")
            or path.startswith(".github/workflows/website-") and path.endswith(".yml"))


def select_stages(paths: list[str] | None, event: str, draft: bool = False) -> tuple[bool, bool, bool]:
    if event == "pull_request" and draft:
        website = any(website_path(path) for path in paths) if paths else True
        return False, website, True
    if not paths or event in {"push", "schedule", "workflow_dispatch"}:
        return True, True, True
    native = not all(
        documentation_only([path])
        or path.startswith(("website/", ".github/assets/"))
        or path == "Branding/shaar-logo.svg"
        or path.startswith(".github/workflows/website-") and path.endswith(".yml")
        for path in paths
    )
    website = any(website_path(path) for path in paths)
    return native, website, True


def uses_fast_lane(name: str) -> bool:
    """Pull requests run the fast lane; the full native pipeline runs once, in the merge queue.

    Running it on both the pull request and its merge group doubled macOS runner use and left
    merge groups waiting for hosted runners.
    """
    return name == "pull_request"


def needs_shipping_probe_guard(paths: list[str] | None) -> bool:
    """Build the shipping executable on PRs that can link probe text into it."""
    if paths is None:
        return True
    return any(
        path in {"Package.swift", "scripts/bundle-app.sh"}
        or (path.startswith("Sources/")
            and not path.startswith(("Sources/ShaarVerification/", "Sources/ChromiumBridgeVerification/"))
            and path.endswith((".swift", ".m", ".mm", ".c", ".cc", ".cpp", ".h", ".inc")))
        for path in paths
    )


def needs_abi_contract(paths: list[str] | None) -> bool:
    """Run the pinned engine contract for ABI inputs and changes to the guard itself."""
    guard_paths = {
        ".github/actions/ci-setup/action.yml",
        ".github/workflows/source-checks.yml",
        "Tests/CIPipelineTests/test_ci_pipeline.py",
        "Tests/EngineMigrationTests/test_abi_contract.py",
        "scripts/check-engine-abi-contract.py",
        "scripts/ci-plan.py",
        "scripts/ci-stage.py",
    }
    return paths is None or any(
        path.startswith(("ThirdParty/ChromiumEngine/", "Sources/ChromiumBridge/"))
        or path in guard_paths
        for path in paths
    )


def iteration_count(event: dict, name: str) -> int:
    if name == "schedule":
        return 3
    if name != "workflow_dispatch":
        return 1
    inputs = event.get("inputs", {})
    if not isinstance(inputs, dict):
        raise ValueError("workflow_dispatch inputs must be an object")
    raw = inputs.get("probe_iterations", 1)
    if type(raw) not in (int, str) or not re.fullmatch(r"[0-9]{1,2}", str(raw)) or not 1 <= int(raw) <= 10:
        raise ValueError("probe_iterations must be an integer from 1 to 10")
    return int(raw)


def merge_group_pr_number(event: dict, name: str) -> str:
    if name != "merge_group":
        return ""
    head_ref = event.get("merge_group", {}).get("head_ref", "")
    if head_ref.startswith("refs/heads/"):
        head_ref = head_ref.removeprefix("refs/heads/")
    match = re.fullmatch(r"gh-readonly-queue/production/pr-([0-9]+)-[0-9a-f]{40}", head_ref)
    if not match:
        return ""
    return match.group(1)


def load_event(path: Path) -> dict:
    try:
        event = json.loads(path.read_text())
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read workflow event JSON from {path}: {error}") from error
    if not isinstance(event, dict):
        raise ValueError(f"workflow event JSON must be an object: {path}")
    return event


def main() -> int:
    try:
        event = load_event(Path(os.environ["GITHUB_EVENT_PATH"]))
        name = os.environ["GITHUB_EVENT_NAME"]
        iterations = iteration_count(event, name)
    except (KeyError, ValueError) as error:
        print(f"CI plan error: {error}", file=sys.stderr)
        return 1
    base = (event.get("pull_request", {}).get("base", {}).get("sha")
            or event.get("merge_group", {}).get("base_sha") or event.get("before")
            or os.environ["GITHUB_SHA"])
    if name == "workflow_dispatch":
        base = subprocess.check_output(["git", "rev-parse", "origin/production"], text=True).strip()
    if name == "push" and base == "0" * 40:
        base = subprocess.check_output(
            ["git", "merge-base", "origin/production", "HEAD"], text=True).strip()
    paths = None
    if name in ("pull_request", "push", "merge_group") and re.fullmatch(r"[0-9a-f]{40}", base) and set(base) != {"0"}:
        result = subprocess.run(["git", "diff", "--name-only", "-z", base, "HEAD"], capture_output=True, check=False)
        if result.returncode == 0:
            paths = decode_changed_paths(result.stdout)
        else:
            print(
                f"::warning::Could not classify changed paths (git diff exited {result.returncode}); "
                "selecting the full CI plan.",
                file=sys.stderr,
            )
    draft = name == "pull_request" and event.get("pull_request", {}).get("draft") is True
    full, website, swift = select_stages(paths, name, uses_fast_lane(name))
    shipping_guard = name == "pull_request" and not draft and needs_shipping_probe_guard(paths)
    abi_contract = name in {"pull_request", "merge_group", "push"} and needs_abi_contract(paths)
    queue_pr = merge_group_pr_number(event, name)
    github_output = output_file(Path(os.environ["GITHUB_OUTPUT"]))
    step_summary = output_file(Path(os.environ["GITHUB_STEP_SUMMARY"]))
    with github_output.open("a") as output:
        output.write(f"full={str(full).lower()}\nbase={base}\niterations={iterations}\nwebsite={str(website).lower()}\nswift={str(swift).lower()}\nqueue_pr={queue_pr}\n")
        output.write(f"shipping_guard={str(shipping_guard).lower()}\n")
        output.write(f"abi_contract={str(abi_contract).lower()}\n")
    with step_summary.open("a") as output:
        output.write(f"### CI selection\n\nFull native pipeline: **{full}**. Draft pull request: **{draft}**. "
                     f"Immutable baseline: `{base}`. "
                     f"Website checks: **{website}**. Swift CodeQL: **{swift}**. Requested probe repetitions: **{iterations}**; private/Quit minimum: **3**.\n")
    return 0


if __name__ == "__main__":
    main()
