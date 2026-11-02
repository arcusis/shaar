#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Install pinned check tools and hooks for this worktree, preserving prior guards."""

import shutil
import subprocess

from ci_support import ROOT
from git_content import run_main
from hook_support import install_hooks


def main() -> None:
    interpreter = ROOT / ".venv/bin/python"
    if not interpreter.is_file() or not shutil.which("swift"):
        raise RuntimeError("Configure .venv and the Swift toolchain first; see CONTRIBUTING.md")
    subprocess.run([str(interpreter), "scripts/install-ci-tools.py"], cwd=ROOT, check=True)
    destination = install_hooks(ROOT)
    print(f"Installed pre-commit and pre-push gates for this worktree: {destination}")
    print("Previous hooks remain chained; global hooks and Git identity are unchanged.")


if __name__ == "__main__":
    raise SystemExit(run_main(main))
