#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Enforce sensitive-file policy and redacted secret scanning on all new commits."""

import argparse
import os
import subprocess
import sys

from ci_support import ROOT
from git_content import commit_id, git, history_commits, object_id, run_main
from sensitive_files import policy_errors


GITLEAKS_TIMEOUT_SECONDS = 300


def scan_history(root, base: str, head: str, report) -> int:
    if report.is_symlink():
        raise ValueError(f"secret scan report must not be a symlink: {report}")
    if report.exists() and not report.is_file():
        raise ValueError(f"secret scan report is not a regular file: {report}")
    errors = []
    for revision in history_commits(root, base, head):
        errors.extend(f"{revision[:12]}: {error}" for error in policy_errors(root, revision))
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        return 1
    report.parent.mkdir(parents=True, exist_ok=True)
    try:
        return subprocess.run(["gitleaks", "git", "--no-banner", "--redact", "--ignore-gitleaks-allow",
                               "--log-level", "warn", "--report-format", "json", "--report-path", str(report),
                               "--log-opts", f"{object_id(base)}..{object_id(head)}", "."], cwd=root,
                              timeout=GITLEAKS_TIMEOUT_SECONDS).returncode
    except subprocess.TimeoutExpired:
        print(f"Gitleaks history scan exceeded {GITLEAKS_TIMEOUT_SECONDS}s", file=sys.stderr)
        return 124


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tree-only", action="store_true")
    options = parser.parse_args()
    if options.tree_only:
        print("Staged-tree scan selected; commit history is checked at push and in CI.")
        return 0
    head = commit_id(ROOT, os.environ.get("CI_HEAD_SHA") or git(ROOT, "rev-parse", "HEAD").decode().strip())
    base = os.environ.get("CI_BASE_SHA")
    if not base:
        if os.environ.get("GITHUB_ACTIONS") == "true":
            raise ValueError("CI history checks require immutable CI_BASE_SHA")
        base = git(ROOT, "merge-base", head, "origin/production").decode().strip()
    return scan_history(ROOT, commit_id(ROOT, base), head, ROOT / "build/ci/fast/history-gitleaks.json")


if __name__ == "__main__":
    raise SystemExit(run_main(main))
