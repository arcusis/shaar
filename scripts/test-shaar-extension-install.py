#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Open hidden Settings and load an unpacked extension through the product path."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def diagnostic_reports():
    root = Path.home() / "Library/Logs/DiagnosticReports"
    if not root.is_dir():
        return {}
    found = {}
    for path in root.iterdir():
        if path.suffix not in {".ips", ".crash", ".spin"}:
            continue
        found[path.name] = path.stat().st_mtime
    return found


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    options = parser.parse_args()
    app = options.app.resolve()
    framework = app / "Contents/Frameworks/Chromium Framework.framework"
    executable = app / "Contents/MacOS/ShaarVerification"
    before = diagnostic_reports()
    with tempfile.TemporaryDirectory(prefix="arcusis-engine-probe-") as temporary:
        root = Path(temporary)
        marker = root / ".arcusis-probe"
        marker.write_text("arcusis-engine-probe-v1\n")
        marker.chmod(0o600)
        (root / "home").mkdir()
        report = root / "initial.json"
        command = [
            str(executable), "--probe-extension-install", "--probe-data-dir", str(root),
            "--probe-framework", str(framework), "--probe-output", str(report),
        ]
        environment = dict(
            os.environ, HOME=str(root / "home"), CFFIXED_USER_HOME=str(root / "home"),
            SHAAR_ENGINE_TESTING="1", RUNNER_TEMP=str(root),
        )
        process = subprocess.run(
            command, env=environment, capture_output=True, text=True, timeout=90, check=False)
        evidence = json.loads(report.read_text()) if report.exists() else None
        after = diagnostic_reports()
        crashes = sorted(
            name for name, mtime in after.items()
            if before.get(name, 0) < mtime and any(
                token in name for token in ("Shaar", "Chromium", "Arcusis")))
        shots = {}
        for name in ("settings-extensions-before.png", "settings-extensions-after.png"):
            path = root / name
            if path.exists():
                saved = options.receipt.parent / name
                saved.write_bytes(path.read_bytes())
                shots[name] = str(saved)
        receipt = {
            "exitCode": process.returncode,
            "report": evidence,
            "screenshots": shots,
            "newCrashReports": crashes,
            "stderrTail": process.stderr[-4000:],
        }
        options.receipt.parent.mkdir(parents=True, exist_ok=True)
        options.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
        passed = bool(evidence and evidence.get("passed")) and not crashes and process.returncode == 0
        print(json.dumps({
            "exitCode": process.returncode,
            "passed": passed,
            "error": None if passed else (evidence or {}).get("error") or "probe failed",
            "newCrashReports": crashes,
        }, indent=2))
        if not passed:
            raise SystemExit(1)


if __name__ == "__main__":
    main()
