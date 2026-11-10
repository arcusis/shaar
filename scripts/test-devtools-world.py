#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Walk a real page in the hidden verification app and save a DevTools receipt."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import threading
import time


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("devtools_fixture", ROOT / "scripts/test-devtools-smoke.py")
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url")
    parser.add_argument("--name", required=True)
    parser.add_argument("--app", type=Path, default=fixture.DEFAULT_APP)
    parser.add_argument("--rebuild", action="store_true")
    parser.add_argument("--spa-only", action="store_true")
    parser.add_argument("--round2", action="store_true")
    parser.add_argument("--hmr-file", type=Path)
    args = parser.parse_args()
    output = ROOT / "build/devtools-world" / args.name
    output.mkdir(parents=True, exist_ok=True)
    app = fixture.ensure_app(args.app.resolve(), args.rebuild)
    executable = app / "Contents/MacOS/ShaarVerification"
    before = fixture.crash_names()
    with fixture.disposable_root() as root:
        home = root / "home"
        home.mkdir()
        report_path = root / "report.json"
        environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home))
        environment["SHAAR_COMPUTED_CAPTURE"] = "1"
        environment.pop("SHAAR_ENGINE_TESTING", None)
        original_hmr = args.hmr_file.read_text() if args.hmr_file else None
        def edit_hmr():
            marker = root / "hmr-ready"
            for _ in range(6000):
                if marker.is_file():
                    if original_hmr is not None and "before-edit" in original_hmr:
                        args.hmr_file.write_text(original_hmr.replace("before-edit", "after-edit"))
                        (root / "hmr-edited").touch()
                    return
                time.sleep(0.1)
        worker = threading.Thread(target=edit_hmr, daemon=True) if args.hmr_file else None
        if worker:
            worker.start()
        mode = "real-world"
        if args.spa_only:
            mode = "spa-only"
        elif args.round2:
            mode = "round-two"
        with (output / "stdout.txt").open("w") as stdout, (output / "stderr.txt").open("w") as stderr:
            try:
                result = subprocess.run(
                    [str(executable), "--devtools-smoke", str(report_path), args.url, mode],
                    env=environment, stdout=stdout, stderr=stderr, timeout=600, check=False,
                )
            except subprocess.TimeoutExpired:
                result = subprocess.CompletedProcess([], 124)
        hmr_ready = (root / "hmr-ready").is_file()
        hmr_edited = (root / "hmr-edited").is_file()
        if original_hmr is not None:
            args.hmr_file.write_text(original_hmr)
        report = json.loads(report_path.read_text()) if report_path.is_file() else {"steps": []}
        for capture in root.glob("world-*.png"):
            shutil.copy2(capture, output / capture.name)
        for artifact in root.glob("world-*.har"):
            shutil.copy2(artifact, output / artifact.name)
        crashes = [name for name in fixture.crash_names() - before
                   if name.startswith(("ArcusisBrowser-", "ShaarVerification-", "Chromium Helper"))]
        crashes.sort()
        steps = report.get("steps", [])
        if not report_path.is_file():
            steps.append({"panel": "Session", "action": "Write report", "passed": False,
                          "severity": "broken", "detail": "App exited without a report"})
        for crash in crashes:
            steps.append({"panel": "Session", "action": "Crash report", "passed": False,
                          "severity": "crash", "detail": crash})
        receipt = {
            "url": args.url, "exitCode": result.returncode,
            "hmrReady": hmr_ready, "hmrEdited": hmr_edited,
            "passedCount": sum(step.get("passed") is True for step in steps),
            "failedCount": sum(step.get("passed") is not True for step in steps),
            "crashes": crashes, "steps": steps,
        }
        (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        fixture.print_table(steps)
        print(f"Summary: {receipt['passedCount']} pass, {receipt['failedCount']} fail, "
              f"exit {result.returncode}, crashes {len(crashes)}", flush=True)
        return 0 if result.returncode == 0 and receipt["failedCount"] == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
