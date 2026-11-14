# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Sensitive path, object-size and symlink policy over indexed or committed bytes."""

import os
from collections import deque
from pathlib import Path, PurePosixPath
import posixpath
import re

from git_content import git, object_id


MAX_FILE_BYTES = 10 * 1024 * 1024
PRIVATE_SUFFIXES = {".p8", ".pem", ".key", ".p12", ".pfx"}
PRIVATE_NAMES = {"id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", ".dev.vars"}


def has_symlink_cycle(name: str, targets: dict[str, str]) -> bool:
    pending = deque(name.split("/"))
    resolved = []
    active = set()
    while pending:
        component = pending.popleft()
        if isinstance(component, tuple):
            active.remove(component[1])
            continue
        if component in ("", "."):
            continue
        if component == "..":
            if resolved:
                resolved.pop()
            continue
        resolved.append(component)
        prefix = "/".join(resolved)
        if prefix in targets:
            if prefix in active:
                return True
            active.add(prefix)
            target = targets[prefix]
            resolved = []
            pending.appendleft(("leave", prefix))
            pending.extendleft(reversed(target.split("/")))
    return False


def blocked_name(name: str) -> bool:
    path = PurePosixPath(name.lower())
    base = path.name
    compact = re.sub(r"[^a-z0-9]", "", base)
    return (path.suffix in PRIVATE_SUFFIXES or base in PRIVATE_NAMES
            or base == ".env" or base.startswith(".env.") or base.endswith(".env")
            or ("sparkle" in compact and any(word in compact for word in ("private", "secret"))))


def indexed_entries(root: Path, revision: str | None) -> list[tuple[str, str, str]]:
    arguments = ("ls-tree", "-rz", object_id(revision)) if revision else ("ls-files", "--stage", "-z")
    entries = []
    for record in git(root, *arguments).split(b"\0"):
        if not record:
            continue
        metadata, raw_name = record.split(b"\t", 1)
        fields = metadata.decode().split()
        mode, oid = (fields[0], fields[2]) if revision else (fields[0], fields[1])
        if not revision and fields[2] != "0":
            raise ValueError("Resolve unmerged index entries before running gates")
        entries.append((mode, object_id(oid), os.fsdecode(raw_name)))
    return entries


def object_sizes(root: Path, entries: list[tuple[str, str, str]]) -> dict[str, int]:
    identifiers = sorted({oid for _, oid, _ in entries})
    if not identifiers:
        return {}
    output = git(root, "cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)",
                 input=("\n".join(identifiers) + "\n").encode())
    sizes = {}
    for line in output.decode().splitlines():
        fields = line.split()
        if len(fields) != 3 or fields[1] != "blob" or not fields[2].isdigit():
            raise ValueError("Every checked entry must be an inspectable Git blob")
        sizes[fields[0]] = int(fields[2])
    if set(sizes) != set(identifiers):
        raise ValueError("Git did not report every indexed object")
    return sizes


def policy_errors(root: Path, revision: str | None = None, *, maximum: int = MAX_FILE_BYTES) -> list[str]:
    entries = indexed_entries(root, revision)
    sizes = object_sizes(root, entries)
    errors = []
    symlink_targets = {}
    for mode, oid, name in entries:
        reason = None
        if blocked_name(name):
            reason = "sensitive filename"
        elif sizes[oid] > maximum:
            reason = "file exceeds 10 MiB limit"
        elif mode == "120000":
            target = os.fsdecode(git(root, "cat-file", "blob", oid))
            resolved = posixpath.normpath(str(PurePosixPath(name).parent / target))
            if target.startswith("/") or "\\" in target or resolved in (".", "..") or resolved.startswith("../"):
                reason = "symlink escapes or cycles to the repository root"
            else:
                symlink_targets[name] = resolved
        elif mode not in ("100644", "100755"):
            reason = "unsupported indexed file mode"
        if reason:
            errors.append(f"{name!r}: {reason}")
    for name in symlink_targets:
        if has_symlink_cycle(name, symlink_targets):
            errors.append(f"{name!r}: symlink cycle")
    return errors
