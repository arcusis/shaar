#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Run the strict hidden media fixture against the locally staged Shaar engine."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
from http.server import ThreadingHTTPServer

from engine_fixture import Fixture


def verification_app_path(value: str) -> Path:
    app = Path(value)
    executable = app / "Contents/MacOS/ShaarVerification"
    if not app.is_dir() or not executable.is_file():
        raise argparse.ArgumentTypeError(
            f"verification app is missing or incomplete: {app}")
    return app


def receipt_output_path(value: str) -> Path:
    path = Path(value)
    if path.is_symlink():
        raise argparse.ArgumentTypeError(f"receipt output must not be a symlink: {path}")
    if path.parent.is_symlink():
        raise argparse.ArgumentTypeError(f"receipt output parent must not be a symlink: {path.parent}")
    return path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=verification_app_path)
    parser.add_argument("--receipt", required=True, type=receipt_output_path)
    options = parser.parse_args()
    app = options.app.resolve()
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        with tempfile.TemporaryDirectory(
            prefix="arcusis-engine-probe-", ignore_cleanup_errors=True
        ) as temporary:
            root = Path(temporary)
            marker = root / ".arcusis-probe"
            marker.write_text("arcusis-engine-probe-v1\n")
            marker.chmod(0o600)
            (root / "home").mkdir()
            report = root / "initial.json"
            fixture = f"http://127.0.0.1:{server.server_port}/account"
            executable = app / "Contents/MacOS/ShaarVerification"
            command = [str(executable), "--probe-data-dir", str(root),
                       "--probe-url", fixture, "--probe-phase", "initial",
                       "--probe-output", str(report), "--probe-media-session-only"]
            environment = dict(os.environ, HOME=str(root / "home"),
                               CFFIXED_USER_HOME=str(root / "home"),
                               SHAAR_ENGINE_TESTING="1", RUNNER_TEMP=str(root))
            try:
                process = subprocess.run(command, env=environment, capture_output=True,
                                         text=True, timeout=180, check=False)
            except subprocess.TimeoutExpired as error:
                options.receipt.write_text(json.dumps({"timeout": True,
                                                       "stderr": str(error)}) + "\n")
                raise
            evidence = json.loads(report.read_text()) if report.exists() else None
            receipt = {"exitCode": process.returncode, "report": evidence,
                       "stderrTail": process.stderr[-4000:]}
            options.receipt.parent.mkdir(parents=True, exist_ok=True)
            options.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
            print(json.dumps({"exitCode": process.returncode,
                              "passed": evidence.get("passed") if evidence else False,
                              "error": evidence.get("error") if evidence else "missing report"},
                             indent=2))
            if process.returncode or not evidence or not evidence.get("passed"):
                raise SystemExit(1)
        server.shutdown()


if __name__ == "__main__":
    main()
