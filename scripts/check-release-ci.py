#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Prepared release gate: require successful full Swift CI on the exact production commit."""

import argparse
import json
import re
import subprocess


def api(path: str) -> dict:
    return json.loads(subprocess.check_output(["gh", "api", path], text=True))


def production_runs(document: dict, revision: str) -> list[dict]:
    return [run for run in document["workflow_runs"]
            if run.get("head_sha") == revision and run.get("head_branch") == "production"
            and run.get("event") == "push" and run.get("status") == "completed"
            and run.get("conclusion") == "success" and type(run.get("id")) is int
            and run["id"] > 0]


def require_release_ci(repository: str, revision: str) -> int:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Expected an owner/repository name")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Release CI requires an immutable 40-character commit")
    prefix = f"repos/{repository}/actions"
    runs = api(f"{prefix}/workflows/source-checks.yml/runs?head_sha={revision}&event=push&branch=production&status=success&per_page=100")
    for run in production_runs(runs, revision):
        jobs = []
        page = 1
        while True:
            batch = api(f"{prefix}/runs/{run['id']}/jobs?per_page=100&page={page}")["jobs"]
            jobs.extend(batch)
            if len(batch) < 100:
                break
            page += 1
        required = {"CI required", "CodeQL / CodeQL swift"}
        successful = {job["name"] for job in jobs
                      if job.get("status") == "completed" and job.get("conclusion") == "success"}
        if required <= successful:
            return run["id"]
    raise ValueError("No successful production Source checks with Swift analysis on this exact commit")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--revision", required=True)
    options = parser.parse_args()
    try:
        run_id = require_release_ci(options.repository, options.revision)
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"Release CI gate failed: {error}")
        return 1
    print(f"Release commit verified: https://github.com/{options.repository}/actions/runs/{run_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
