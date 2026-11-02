#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Replay fresh native Swift compilations without tracing SwiftPM's manifest interpreter."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import shlex
import subprocess
import time

from ci_support import Commands, ROOT, swift_source_files, file_sha256
from swift_build_plan import manifest_commands, native_command_log, ordered_modules, prepare_inputs


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
            if path == root / "Package.swift" or any(
                path.is_relative_to(root / directory) for directory in ("Sources", "Tests", "Plugins")
            ):
                sources.add(path.relative_to(root).as_posix())
    return sources


def validate_compilation(arguments: list[str]) -> None:
    if "-whole-module-optimization" not in arguments or "-target" not in arguments:
        raise ValueError("Swift analysis must freshly compile complete arm64 modules")
    target = arguments[arguments.index("-target") + 1]
    if not target.startswith("arm64-apple-macosx"):
        raise ValueError("Swift analysis must target the shipping arm64 architecture")


def compiler_commands(log: str, root: Path, compiler: Path, expected: set[str]) -> list[list[str]]:
    commands = []
    covered = set()
    for line in log.splitlines():
        if not line.startswith(str(compiler) + " "):
            continue
        arguments = shlex.split(line)
        if "-module-name" not in arguments or "-whole-module-optimization" not in arguments:
            continue
        validate_compilation(arguments)
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


def swift_build_arguments(scratch: str) -> list[str]:
    return ["swift", "build", "--build-system", "native", "--jobs", "2", "--force-resolved-versions",
                 "--scratch-path", scratch, "--arch", "arm64", "--disable-index-store", "--verbose",
                 "-Xswiftc", "-whole-module-optimization", "-Xswiftc", "-Onone",
                 "-Xswiftc", "-num-threads", "-Xswiftc", "2",
                 "-Xswiftc", "-no-emit-module-separately-wmo"]


def prepare(scope: str) -> int:
    checks = Commands("codeql-prepare")
    compiler = Path(subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip())
    scratch = ROOT / "build/swiftpm" / ("codeql-semantic" if scope == "all" else "codeql")
    if scope != "all" and checks.run("clean", ["swift", "package", "--scratch-path", str(scratch), "clean"]):
        return checks.finish()
    arguments = [*swift_build_arguments(str(scratch)),
                 *( ["--build-tests"] if scope == "all" else ["--print-manifest-job-graph"])]
    if checks.run("native-build-plan", arguments):
        return checks.finish()
    sources = source_hashes(ROOT, scope)
    all_sources = {name: digest for name, digest in source_hashes(ROOT, scope if scope == "all" else "full").items()
                   if name.startswith(("Sources/", "Tests/"))}
    manifest = manifest_commands(scratch / "debug.yaml")
    if scope != "all":
        prepare_inputs(manifest, ROOT, scratch)
    commands = compiler_commands(native_command_log(manifest, compiler), ROOT, compiler, set(all_sources))
    commands = ordered_modules(manifest, commands)
    commands = [command for command in commands if command_sources(command, ROOT) <= set(sources)]
    if scope == "all":
        commands.extend(configuration_commands(compiler, set(sources) - set(all_sources)))
    PLAN.parent.mkdir(parents=True, exist_ok=True)
    PLAN.write_text(json.dumps(dict(identity(), scope=scope, compiler=str(compiler), compiler_sha256=file_sha256(compiler), sources=sources, commands=commands), indent=2) + "\n")
    return checks.finish()


def validated_plan(scope: str) -> dict:
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
    covered = set()
    for arguments in plan["commands"]:
        if arguments[0] != str(compiler):
            raise ValueError("Compiler plan executable changed")
        validate_compilation(arguments)
        covered |= command_sources(arguments, ROOT)
    if covered != set(plan["sources"]):
        raise ValueError("Compiler response files changed after planning")
    return plan


def replay(scope: str = "full") -> int:
    plan = validated_plan(scope)
    checks = Commands("codeql-swift")
    for arguments in plan["commands"]:
        module = arguments[arguments.index("-module-name") + 1]
        if checks.run(module, arguments):
            return checks.finish()
    return checks.finish()


def configuration_commands(compiler: Path, sources: set[str]) -> list[list[str]]:
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    api = compiler.parent.parent / "lib/swift/pm"
    commands = []
    for source in sorted(sources):
        manifest = source == "Package.swift"
        if not manifest and not source.startswith("Plugins/"):
            raise ValueError(f"Swift source outside the native target graph: {source}")
        commands.append([str(compiler), "-module-name", "PackageManifest" if manifest else "BuildPlugin",
                         "-whole-module-optimization", "-target", "arm64-apple-macosx26.0", "-sdk", sdk,
                         "-swift-version", "6", "-package-description-version", "6.2.0",
                         "-I", str(api / ("ManifestAPI" if manifest else "PluginAPI")),
                         *([] if manifest else ["-parse-as-library"]), "-typecheck", str(ROOT / source)])
    return commands


def typecheck_arguments(arguments: list[str]) -> list[str]:
    flags = {"-c", "-emit-module", "-emit-dependencies", "-incremental", "-enable-batch-mode",
             "-emit-objc-header", "-serialize-diagnostics", "-typecheck"}
    pairs = {"-output-file-map", "-emit-module-path", "-emit-objc-header-path", "-o",
             "-emit-module-doc-path", "-emit-module-source-info-path", "-module-cache-path"}
    result = []
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument in pairs:
            if index + 1 == len(arguments):
                raise ValueError("Swift output option has no value")
            index += 2
        else:
            if argument not in flags:
                result.append(argument)
            index += 1
    return [*result, "-module-cache-path", str(ROOT / "build/codeql-sdk-modules"), "-typecheck"]


def semantic_build() -> int:
    plan = validated_plan("all")
    def extract(arguments: list[str]) -> Commands:
        module = arguments[arguments.index("-module-name") + 1]
        checks = Commands(f"codeql-swift/{module}")
        checks.run(module, typecheck_arguments(arguments))
        return checks

    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(extract, plan["commands"]))
    statuses = [checks.finish() for checks in results]
    return int(any(statuses))


def full_build() -> int:
    scratch = "build/swiftpm/codeql-full"
    if (ROOT / scratch).exists():
        raise ValueError("Full Swift analysis requires a fresh scratch directory")
    checks = Commands("codeql-swift")
    checks.run("full-build", [*swift_build_arguments(scratch), "--manifest-cache", "none"])
    return checks.finish()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("prepare", "replay", "full", "semantic"))
    parser.add_argument("--scope", choices=("all", "full", "shipping"), default="all")
    options = parser.parse_args()
    if options.mode == "full":
        return full_build()
    if options.mode == "semantic":
        return semantic_build()
    return prepare(options.scope) if options.mode == "prepare" else replay(options.scope)


if __name__ == "__main__":
    raise SystemExit(main())
