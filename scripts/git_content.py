# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Read exact Git content and export disposable check snapshots without commits."""

from contextlib import contextmanager
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


OID = re.compile(r"[0-9a-f]{40}")


def git(root: Path, *arguments: str, env=None, input=None) -> bytes:
    return subprocess.run(["git", *arguments], cwd=root, env=env, input=input,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout


def run_main(action) -> int:
    try:
        return int(action() or 0)
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Shaar gate failed: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr.decode(errors="replace"), file=sys.stderr)
        return 1


def object_id(value: str) -> str:
    if not OID.fullmatch(value):
        raise ValueError("Expected an immutable 40-character Git object ID")
    return value


def commit_id(root: Path, value: str) -> str:
    return object_id(git(root, "rev-parse", "--verify", object_id(value) + "^{commit}").decode().strip())


def history_commits(root: Path, base: str, head: str) -> list[str]:
    base, head = commit_id(root, base), commit_id(root, head)
    return git(root, "rev-list", "--reverse", f"{base}..{head}").decode().splitlines()


def push_updates(data: bytes) -> list[tuple[str, str]]:
    updates = []
    for line in data.decode("utf-8").splitlines():
        fields = line.split()
        if len(fields) != 4:
            raise ValueError("Malformed pre-push ref list")
        _, head, _, base = fields
        object_id(head)
        object_id(base)
        if head != "0" * 40 and (head, base) not in updates:
            updates.append((head, base))
    return updates


def push_base(root: Path, head: str, remote: str) -> str:
    if remote != "0" * 40:
        try:
            return commit_id(root, remote)
        except subprocess.CalledProcessError:
            pass
    return object_id(git(root, "merge-base", commit_id(root, head), "origin/production").decode().strip())


def detached_environment(root: Path) -> dict[str, str]:
    environment = dict(os.environ)
    for name in git(root, "rev-parse", "--local-env-vars").decode().splitlines():
        environment.pop(name, None)
    for name in tuple(environment):
        if name.startswith(("GIT_CONFIG_KEY_", "GIT_CONFIG_VALUE_")):
            environment.pop(name)
    return environment


@contextmanager
def snapshot(root: Path, tree: str, *, head: str | None = None):
    object_id(tree)
    with tempfile.TemporaryDirectory(prefix="shaar-gates-") as temporary:
        directory = Path(temporary).resolve()
        source = directory / "source"
        source.mkdir()
        export_environment = dict(os.environ, GIT_INDEX_FILE=str(directory / "export-index"))
        git(root, "read-tree", tree, env=export_environment)
        git(root, "checkout-index", "--all", "--prefix", str(source) + "/", env=export_environment)
        environment = detached_environment(root)
        git(source, "init", "--quiet", env=environment)
        objects = git(root, "rev-parse", "--path-format=absolute", "--git-path", "objects").decode().strip()
        (source / ".git/objects/info/alternates").write_text(objects + "\n")
        git(source, "read-tree", tree, env=environment)
        if head:
            git(source, "-c", "core.hooksPath=/dev/null", "update-ref", "HEAD", commit_id(root, head), env=environment)
        yield source, environment
