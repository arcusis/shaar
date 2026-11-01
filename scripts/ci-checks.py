#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Shared fast gates. Missing tools or checks fail rather than silently skipping."""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

from ci_support import Commands, ROOT


def pin_errors(root: Path) -> list[str]:
    errors = []
    for path in sorted((root / ".github").rglob("*.y*ml")):
        for number, line in enumerate(path.read_text().splitlines(), 1):
            match = re.match(r"\s*(?:-\s*)?uses:\s*(.*?)\s*$", line)
            if not match:
                continue
            action = match[1].split(" #", 1)[0].strip("\"'")
            if not (action.startswith("./") or re.fullmatch(r"[\w./-]+@[0-9a-f]{40}", action)):
                errors.append(f"{path.relative_to(root)}:{number}: action must use a full SHA")
    lock = json.loads((root / "Package.resolved").read_text())
    if not lock.get("pins"):
        errors.append("Package.resolved has no dependency pins")
    for pin in lock.get("pins", []):
        state = pin.get("state", {})
        if not re.fullmatch(r"[0-9a-f]{40}", state.get("revision", "")) or not state.get("version"):
            errors.append(f"Unpinned Swift dependency: {pin.get('identity')}")
    return errors


def tracked_shell_files() -> list[str]:
    files = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
    return [name for name in files if name.endswith(".sh") and not name.startswith("ThirdParty/")]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pins-only", action="store_true")
    options = parser.parse_args()
    errors = pin_errors(ROOT)
    for error in errors:
        print(error, file=sys.stderr)
    if options.pins_only:
        return int(bool(errors))
    checks = Commands("fast")
    commands = [
        ("format", ["swift", "format", "lint", "--strict", "--recursive", "Package.swift", "Sources", "Tests"]),
        ("license", [sys.executable, "scripts/check-license-headers.py"]),
        ("notebook", [sys.executable, "scripts/check-notebook-links.py"]),
        ("localization", [sys.executable, "scripts/check-localization.py"]),
        ("actionlint", ["actionlint", "-color"]),
        ("shellcheck", ["shellcheck", "-x", *tracked_shell_files()]),
        ("pins", [sys.executable, __file__, "--pins-only"]),
        ("gitleaks", ["gitleaks", "dir", "--no-banner", "--redact", "--log-level", "warn",
                      "--report-format", "json", "--report-path", "build/ci/fast/gitleaks.json", "."]),
        ("python", [sys.executable, "scripts/test-python.py", "--junit", "build/ci/fast/python.xml"]),
    ]
    for name, arguments in commands:
        checks.run(name, arguments)
    return checks.finish()


if __name__ == "__main__":
    raise SystemExit(main())
