#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Replay fresh native Swift compilations without tracing SwiftPM's manifest interpreter."""

import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import time

from ci_support import Commands, ROOT, SWIFT_SOURCE_ROOTS, swift_source_files, file_sha256


PLAN = ROOT / "build/ci/codeql-swift/compile-plan.json"


def source_hashes(root: Path, scope: str = "full", *, tracked: bool = True) -> dict[str, str]:
    return {name: file_sha256(root / name)
            for name in sorted(swift_source_files(root, scope, tracked=tracked))}


def command_sources(arguments: list[str], root: Path) -> set[str]:
    root = root.resolve()
    expanded = []
    for argument in arguments:
        if argument.startswith("@"):
            response = (root / argument[1:]).resolve()
            if not response.is_relative_to(root / "build") or response.stat().st_size > 1024 * 1024:
                raise ValueError("Unexpected Swift compiler response file")
            expanded.extend(shlex.split(response.read_text()))
        else:
            expanded.append(argument)
    sources = set()
    for argument in expanded:
        if argument.endswith(".swift"):
            path = (root / argument).resolve()
            if any(path.is_relative_to(root / directory) for directory in SWIFT_SOURCE_ROOTS):
                sources.add(path.relative_to(root).as_posix())
    return sources


def compiler_commands(log: str, root: Path, compiler: Path, expected: set[str]) -> list[list[str]]:
    commands = []
    covered = set()
    for line in log.splitlines():
        if not line.startswith(str(compiler) + " "):
            continue
        arguments = shlex.split(line)
        if "-module-name" not in arguments or "-whole-module-optimization" not in arguments:
            continue
        sources = command_sources(arguments, root)
        if not sources:
            continue
        if sources & covered:
            raise ValueError("Duplicate Swift module compiler invocation")
        if "-v" in arguments:
            arguments.remove("-v")
        commands.append(arguments)
        covered |= sources
    if not expected or covered != expected:
        raise ValueError(f"Native compiler plan omitted Swift sources: {sorted(expected - covered)}")
    return commands


def identity() -> dict:
    return {"revision": os.environ["GITHUB_SHA"], "toolchain": os.environ["CI_TOOLCHAIN_ID"]}


def prepare(scope: str) -> int:
    checks = Commands("codeql-prepare")
    compiler = Path(subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip())
    if checks.run("clean", ["swift", "package", "--scratch-path", "build/swiftpm/codeql", "clean"]):
        return checks.finish()
    arguments = ["swift", "build", "--build-system", "native", "--jobs", "2", "--force-resolved-versions",
                 "--scratch-path", "build/swiftpm/codeql", "--disable-index-store", "--verbose",
                 "-Xswiftc", "-whole-module-optimization", "-Xswiftc", "-Onone",
                 "-Xswiftc", "-num-threads", "-Xswiftc", "2",
                 "-Xswiftc", "-no-emit-module-separately-wmo"]
    if checks.run("native-build-plan", arguments):
        return checks.finish()
    sources = source_hashes(ROOT, scope)
    all_sources = source_hashes(ROOT)
    commands = compiler_commands((checks.directory / "native-build-plan.log").read_text(), ROOT, compiler, set(all_sources))
    commands = [command for command in commands if command_sources(command, ROOT) <= set(sources)]
    commands.sort(key=lambda command: command[command.index("-module-name") + 1] != "BrowserTestSupport")
    PLAN.parent.mkdir(parents=True, exist_ok=True)
    PLAN.write_text(json.dumps(dict(identity(), scope=scope, compiler=str(compiler), compiler_sha256=file_sha256(compiler), sources=sources, commands=commands), indent=2) + "\n")
    return checks.finish()


def replay(scope: str = "full") -> int:
    started = time.monotonic()
    plan = json.loads(PLAN.read_text())
    if plan.get("scope") != scope:
        raise ValueError("Swift compiler plan analysis scope changed")
    if any(plan.get(key) != value for key, value in identity().items()) or plan["sources"] != source_hashes(ROOT, scope, tracked=False):
        raise ValueError("Swift compiler plan commit, toolchain or source content changed")
    source_validation = time.monotonic() - started
    compiler = Path(plan["compiler"])
    if not compiler.is_absolute() or file_sha256(compiler) != plan["compiler_sha256"]:
        raise ValueError("Swift compiler changed after planning")
    (PLAN.parent / "validation.json").write_text(json.dumps({
        "source_seconds": round(source_validation, 3),
        "compiler_seconds": round(time.monotonic() - started - source_validation, 3),
    }, indent=2) + "\n")
    checks = Commands("codeql-swift")
    covered = set()
    for arguments in plan["commands"]:
        if arguments[0] != str(compiler) or "-whole-module-optimization" not in arguments:
            raise ValueError("Compiler plan must freshly compile whole Swift modules")
        covered |= command_sources(arguments, ROOT)
        module = arguments[arguments.index("-module-name") + 1]
        if checks.run(module, arguments):
            return checks.finish()
    if covered != set(plan["sources"]):
        raise ValueError("Compiler response files changed after planning")
    return checks.finish()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("prepare", "replay"))
    parser.add_argument("--scope", choices=("full", "shipping"), default="full")
    options = parser.parse_args()
    return prepare(options.scope) if options.mode == "prepare" else replay(options.scope)


if __name__ == "__main__":
    raise SystemExit(main())
