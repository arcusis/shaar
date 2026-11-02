#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Require exact production CI, Swift security and zero open code-scanning alerts."""

import argparse
import json
import re
import subprocess


def api(path: str) -> dict | list:
    return json.loads(subprocess.check_output(["gh", "api", path], text=True))


def production_runs(document: dict, revision: str) -> list[dict]:
    return [run for run in document["workflow_runs"]
            if run.get("head_sha") == revision and run.get("head_branch") == "production"
            and run.get("event") == "push" and run.get("status") == "completed"
            and run.get("conclusion") == "success" and type(run.get("id")) is int
            and run["id"] > 0]


def require_workflow(repository: str, revision: str, workflow: str, required: set[str]) -> int:
    prefix = f"repos/{repository}/actions"
    runs = api(f"{prefix}/workflows/{workflow}/runs?head_sha={revision}&event=push&branch=production&status=success&per_page=100")
    for run in production_runs(runs, revision):
        jobs = []
        page = 1
        while True:
            batch = api(f"{prefix}/runs/{run['id']}/jobs?per_page=100&page={page}")["jobs"]
            jobs.extend(batch)
            if len(batch) < 100:
                break
            page += 1
        successful = {job["name"] for job in jobs
                      if job.get("status") == "completed" and job.get("conclusion") == "success"}
        if required <= successful:
            return run["id"]
    raise ValueError(f"No successful production {workflow} on this exact commit")


def require_no_open_alerts(repository: str) -> None:
    alerts = api(f"repos/{repository}/code-scanning/alerts?state=open&per_page=1")
    if not isinstance(alerts, list) or alerts:
        raise ValueError("Release blocked: open code-scanning alerts or invalid alert response")


def require_release_ci(repository: str, revision: str) -> dict[str, int]:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Expected an owner/repository name")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Release CI requires an immutable 40-character commit")
    runs = {
        "Source checks": require_workflow(repository, revision, "source-checks.yml", {"CI required"}),
        "Swift security": require_workflow(repository, revision, "swift-security.yml", {"Swift security required"}),
    }
    require_no_open_alerts(repository)
    return runs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--revision")
    parser.add_argument("--alerts-only", action="store_true")
    options = parser.parse_args()
    try:
        if options.alerts_only:
            require_no_open_alerts(options.repository)
            print("No open code-scanning alerts")
            return 0
        if not options.revision:
            raise ValueError("Exact-commit release gate requires --revision")
        runs = require_release_ci(options.repository, options.revision)
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"Release CI gate failed: {error}")
        return 1
    for name, run_id in runs.items():
        print(f"{name} verified: https://github.com/{options.repository}/actions/runs/{run_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
