#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Exercise the pinned engine's Shaar DevTools panels in a hidden fixture app."""

import argparse
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading

from engine_fixture import Fixture


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    options = parser.parse_args()
    app = options.app.resolve()
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        with tempfile.TemporaryDirectory(prefix="arcusis-engine-probe-") as temporary:
            root = Path(temporary)
            (root / ".arcusis-probe").write_text("arcusis-engine-probe-v1\n")
            (root / "home").mkdir()
            report = root / "initial.json"
            details = root / "initial-devtools-panels.json"
            executable = app / "Contents/MacOS/ShaarVerification"
            command = [
                str(executable), "--probe-data-dir", str(root),
                "--probe-url", f"http://127.0.0.1:{server.server_port}/account",
                "--probe-phase", "initial", "--probe-output", str(report),
                "--probe-devtools-panels-only",
            ]
            environment = dict(
                os.environ, HOME=str(root / "home"), CFFIXED_USER_HOME=str(root / "home"),
                SHAAR_ENGINE_TESTING="1", RUNNER_TEMP=str(root),
            )
            process = subprocess.run(
                command, env=environment, capture_output=True, text=True,
                timeout=220, check=False,
            )
            evidence = json.loads(report.read_text()) if report.exists() else None
            panel = json.loads(details.read_text()) if details.exists() else None
            receipt = {
                "command": command,
                "exitCode": process.returncode,
                "report": evidence,
                "panels": panel,
                "stderrTail": process.stderr[-8000:],
            }
            options.receipt.parent.mkdir(parents=True, exist_ok=True)
            options.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
            print(json.dumps({
                "exitCode": process.returncode,
                "panels": panel["results"] if panel else None,
                "error": evidence.get("error") if evidence else "missing report",
            }, indent=2))
            if process.returncode or not evidence or not evidence.get("passed"):
                raise SystemExit(1)
        server.shutdown()


if __name__ == "__main__":
    main()
