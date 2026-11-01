#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Classify only a narrow documentation-only diff as safe to skip native stages."""

import json
import os
import re
import subprocess
from pathlib import Path


def documentation_only(paths: list[str]) -> bool:
    root_documents = {"README.md", "CONTRIBUTING.md", "CREDITS.md", "SECURITY.md"}
    return bool(paths) and all(
        path in root_documents or path.startswith("Notebook/") and path.endswith(".md")
        for path in paths
    )


def iteration_count(event: dict, name: str) -> int:
    if name == "schedule":
        return 3
    if name != "workflow_dispatch":
        return 1
    raw = event.get("inputs", {}).get("probe_iterations", 1)
    if type(raw) not in (int, str) or not re.fullmatch(r"[0-9]{1,2}", str(raw)) or not 1 <= int(raw) <= 10:
        raise ValueError("probe_iterations must be an integer from 1 to 10")
    return int(raw)


def main() -> None:
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    name = os.environ["GITHUB_EVENT_NAME"]
    iterations = iteration_count(event, name)
    base = (event.get("pull_request", {}).get("base", {}).get("sha")
            or event.get("merge_group", {}).get("base_sha") or event.get("before")
            or os.environ["GITHUB_SHA"])
    if name == "workflow_dispatch":
        base = subprocess.check_output(["git", "rev-parse", "origin/production"], text=True).strip()
    full = True
    if name in ("pull_request", "push", "merge_group") and re.fullmatch(r"[0-9a-f]{40}", base) and set(base) != {"0"}:
        result = subprocess.run(["git", "diff", "--name-only", "-z", base, "HEAD"], capture_output=True, check=False)
        if result.returncode == 0:
            full = not documentation_only([path for path in result.stdout.decode().split("\0") if path])
    with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
        output.write(f"full={str(full).lower()}\nbase={base}\niterations={iterations}\n")
    with Path(os.environ["GITHUB_STEP_SUMMARY"]).open("a") as output:
        output.write(f"### CI selection\n\nFull native pipeline: **{full}**. Immutable baseline: `{base}`. "
                     f"Requested probe repetitions: **{iterations}**; private/Quit minimum: **3**.\n")


if __name__ == "__main__":
    main()
