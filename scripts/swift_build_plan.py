# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Read native SwiftPM command arrays and prepare compiler-only prerequisites."""

import json
from pathlib import Path
import shlex
import shutil


def manifest_commands(path: Path) -> list[dict]:
    commands = []
    current = None
    active = False
    for line in path.read_text().splitlines():
        if line == "commands:":
            active = True
            continue
        if not active:
            continue
        if line.startswith("  ") and not line.startswith("    ") and line.endswith(":"):
            current = {}
            commands.append(current)
        elif current is not None and line.startswith("    "):
            key, _, value = line.strip().partition(": ")
            if key in {"inputs", "outputs", "args"}:
                values = json.loads(value)
                if not isinstance(values, list) or any(not isinstance(item, str) for item in values):
                    raise ValueError("Unsupported SwiftPM command field")
                current[key] = values
            elif key == "tool":
                current[key] = value.strip('"')
    if not commands:
        raise ValueError("SwiftPM manifest has no native commands")
    return commands


def output_path(value: str, root: Path, scratch: Path) -> Path:
    path = (root / value).resolve()
    if not path.is_relative_to(scratch.resolve()):
        raise ValueError("SwiftPM output escaped the analysis scratch directory")
    return path


def prepare_inputs(commands: list[dict], root: Path, scratch: Path) -> None:
    for command in commands:
        for value in command.get("outputs", []):
            if not value.startswith("<"):
                output_path(value, root, scratch).parent.mkdir(parents=True, exist_ok=True)
        inputs = command.get("inputs", [])
        if command.get("tool") == "write-auxiliary-file" and inputs[:1] == ["<sources-file-list>"]:
            destination = output_path(command["outputs"][0], root, scratch)
            destination.write_text("\n".join(shlex.quote(value) for value in inputs[1:]) + "\n")
        elif command.get("tool") == "copy-tool":
            if len(inputs) != 1 or len(command.get("outputs", [])) != 1:
                raise ValueError("Unsupported SwiftPM copy command")
            source = (root / inputs[0]).resolve()
            if not source.is_relative_to(root.resolve()):
                raise ValueError("SwiftPM copy source escaped the checkout")
            destination = output_path(command["outputs"][0], root, scratch)
            if source.is_dir():
                shutil.copytree(source, destination, symlinks=True, dirs_exist_ok=True)
            else:
                shutil.copy2(source, destination)


def native_command_log(commands: list[dict], compiler: Path) -> str:
    return "\n".join(shlex.join(command["args"]) for command in commands
                     if command.get("tool") == "shell" and command.get("args", [None])[0] == str(compiler))


def ordered_modules(commands: list[dict], arguments: list[list[str]]) -> list[list[str]]:
    pending = {item[item.index("-module-name") + 1]: item for item in arguments}
    producers = {item[item.index("-emit-module-path") + 1]: name for name, item in pending.items()}
    inputs = {item["args"][item["args"].index("-module-name") + 1]: item.get("inputs", [])
              for item in commands if "-module-name" in item.get("args", [])}
    ordered = []
    while pending:
        ready = sorted((name for name in pending if not any(producers.get(path) in pending for path in inputs[name])),
                       key=lambda name: (name != "BrowserTestSupport", name))
        if not ready:
            raise ValueError("SwiftPM module dependencies contain a cycle")
        for name in ready:
            ordered.append(pending.pop(name))
    return ordered


def parallel_module_batches(commands: list[dict], arguments: list[list[str]],
                             max_parallel: int = 2) -> list[list[list[str]]]:
    """Group independent native compiler jobs while preserving module dependencies."""
    if max_parallel < 1:
        raise ValueError("Module parallelism must be positive")
    pending = {item[item.index("-module-name") + 1]: item for item in arguments}
    if len(pending) != len(arguments):
        raise ValueError("Duplicate Swift module compiler invocation")
    producers = {item[item.index("-emit-module-path") + 1]: name for name, item in pending.items()}
    inputs = {item["args"][item["args"].index("-module-name") + 1]: item.get("inputs", [])
              for item in commands if "-module-name" in item.get("args", [])}
    batches = []
    while pending:
        ready = sorted((name for name in pending
                        if not any(producers.get(path) in pending for path in inputs[name])),
                       key=lambda name: (name != "BrowserTestSupport", name))
        if not ready:
            raise ValueError("SwiftPM module dependencies contain a cycle")
        batch = ready[:max_parallel]
        batches.append([pending.pop(name) for name in batch])
    return batches
