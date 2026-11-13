# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Worktree-scoped installation, prior-hook chaining and exact content checks."""

import os
from pathlib import Path
import subprocess
import sys

from git_content import git, object_id, push_base, push_updates, snapshot
from sensitive_files import policy_errors


def config(root: Path, key: str, *, scope: str | None = None, path_value: bool = False) -> str | None:
    arguments = ["config", *([scope] if scope else []), *(["--path"] if path_value else []), "--get", key]
    try:
        return git(root, *arguments).decode().removesuffix("\n")
    except subprocess.CalledProcessError as error:
        if error.returncode != 1:
            raise
        return None


def install_hooks(root: Path) -> Path:
    if config(root, "core.worktree", scope="--local") or config(root, "core.bare", scope="--local") == "true":
        raise ValueError("Worktree hook installation requires prior core.worktree/core.bare migration")
    git_directory = Path(git(root, "rev-parse", "--absolute-git-dir").decode().strip())
    destination = git_directory / "shaar-hooks"
    if destination.is_symlink():
        raise ValueError("Managed hook directory must not be a symlink")
    previous = config(root, "core.hooksPath", path_value=True)
    if previous and (root / previous).resolve() == destination.resolve():
        previous = config(root, "shaar.previousHooksPath", scope="--worktree", path_value=True)
        if previous is None:
            raise ValueError("Managed hook path has no saved previous hook chain")
    else:
        if previous is None:
            previous = str(Path(git(root, "rev-parse", "--path-format=absolute", "--git-common-dir").decode().strip()) / "hooks")
        git(root, "config", "--local", "extensions.worktreeConfig", "true")
        git(root, "config", "--worktree", "shaar.previousHooksPath", previous)
    launcher = (root / ".githooks/run.sh").read_bytes()
    destination.mkdir(parents=True, exist_ok=True)
    prior = root / previous
    names = {"pre-commit", "pre-push"}
    if prior.is_dir():
        names.update(path.name for path in prior.iterdir()
                     if path.is_file() and os.access(path, os.X_OK) and not path.name.endswith(".sample"))
    for name in sorted(names):
        path = destination / name
        if path.is_symlink():
            raise ValueError("Managed hook launcher must not be a symlink")
        path.write_bytes(launcher)
        path.chmod(0o755)
    git(root, "config", "--worktree", "core.hooksPath", str(destination))
    return destination


def chain_previous(root: Path, stage: str, arguments: list[str], data: bytes | None) -> int:
    previous = config(root, "shaar.previousHooksPath", scope="--worktree", path_value=True)
    if not previous:
        return 0
    hook = root / previous / stage
    if not hook.is_file() or not os.access(hook, os.X_OK):
        return 0
    if os.environ.get("SHAAR_HOOK_CHAIN_ACTIVE"):
        raise ValueError("Recursive previous-hook chaining refused")
    environment = dict(os.environ, SHAAR_HOOK_CHAIN_ACTIVE="1")
    return subprocess.run([str(hook), *arguments], cwd=root, input=data, env=environment).returncode


def check_tree(root: Path, tree: str, *, head: str | None = None, base: str | None = None) -> int:
    errors = policy_errors(root, tree)
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        return 1
    interpreter = root / ".venv/bin/python"
    if not interpreter.is_file():
        raise ValueError("Configured .venv Python is missing")
    with snapshot(root, tree, head=head) as (source, environment):
        environment["PATH"] = str(root / "build/ci-tools") + os.pathsep + environment.get("PATH", "")
        environment.pop("CI_BASE_SHA", None)
        environment.pop("CI_HEAD_SHA", None)
        if base:
            environment.update(CI_BASE_SHA=base, CI_HEAD_SHA=head)
        arguments = [str(interpreter), "scripts/ci-checks.py", *([] if head else ["--snapshot-only"])]
        return subprocess.run(arguments, cwd=source, env=environment).returncode


def run_hook(root: Path, stage: str, arguments: list[str], data: bytes | None = None) -> int:
    status = chain_previous(root, stage, arguments, data)
    if status:
        return status
    if stage == "pre-commit":
        return check_tree(root, object_id(git(root, "write-tree").decode().strip()))
    if stage != "pre-push":
        raise ValueError("Unsupported hook stage")
    for head, remote in push_updates(data or b""):
        base = push_base(root, head, remote)
        status = check_tree(root, head, head=head, base=base)
        if status:
            return status
    return 0
