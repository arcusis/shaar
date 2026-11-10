#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Prove the real device APIs return in a hidden verification bundle without a main-thread stall."""

import argparse
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import tempfile
import threading


ROOT = Path(__file__).resolve().parents[1]
CRASHES = Path.home() / "Library/Logs/DiagnosticReports"
CALLS = {
    "serial": "navigator.serial.requestPort()",
    "bluetooth": "navigator.bluetooth.requestDevice({acceptAllDevices:true})",
    "usb": "navigator.usb.requestDevice({filters:[]})",
    "hid": "navigator.hid.requestDevice({filters:[]})",
}


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        kind = self.path.strip("/").split("?", 1)[0]
        call = CALLS.get(kind)
        if call is None:
            self.send_error(404)
            return
        body = f"""<!doctype html><meta charset="utf-8"><title>{kind}</title>
<button id="parity-action">Request</button>
<script>
document.getElementById("parity-action").addEventListener("click", () => {{
  ({call}).then((value) => {{
    const count = Array.isArray(value) ? value.length : (value == null ? 0 : 1);
    window.__shaarChooserResult = {{ok: true, count: count}};
  }}, (error) => {{
    window.__shaarChooserResult = {{
      error: error && error.name ? error.name : "Error",
      message: String(error && error.message || error)
    }};
  }});
}});
</script>"""
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *args):
        pass


def crash_names():
    names = set()
    for directory in (CRASHES, CRASHES / "Retired"):
        if directory.is_dir():
            names.update(
                path.name for path in directory.iterdir()
                if path.suffix in {".ips", ".crash"}
                and path.name.startswith(("Shaar", "ArcusisBrowser", "Chromium", "ShaarVerification"))
            )
    return names


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "build/Shaar Verification.app")
    options = parser.parse_args()
    executable = options.app / "Contents/MacOS/ShaarVerification"
    framework = options.app / "Contents/Frameworks/Chromium Framework.framework"
    if not executable.is_file() or not framework.is_dir():
        parser.error(f"Missing verification bundle: {options.app}")
    before = crash_names()
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        root = Path(tempfile.mkdtemp(prefix="arcusis-engine-probe-device-chooser-parent-"))
        data = root / "arcusis-engine-probe-device-choosers"
        data.mkdir(mode=0o700)
        data.chmod(0o700)
        marker = data / ".arcusis-probe"
        marker.write_text("arcusis-engine-probe-v1\n")
        marker.chmod(0o600)
        home = root / "home"
        home.mkdir()
        report = data / "report.json"
        page = f"http://127.0.0.1:{server.server_port}/"
        command = [
            str(executable), "--probe-device-choosers", "--probe-framework", str(framework),
            "--probe-output", str(report), "--probe-data-dir", str(data),
            "--probe-base-url", page,
        ]
        environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home),
                           SHAAR_ENGINE_TESTING="1", RUNNER_TEMP=str(root))
        process = subprocess.run(command, env=environment, capture_output=True, text=True,
                                 timeout=120, check=False)
        evidence = json.loads(report.read_text()) if report.exists() else None
        new_crashes = sorted(crash_names() - before)
        print(json.dumps({
            "exitCode": process.returncode,
            "passed": bool(evidence and evidence.get("passed")),
            "bluetoothIOBlocked": evidence.get("bluetoothIOBlocked") if evidence else None,
            "maxStallSeconds": evidence.get("maxStallSeconds") if evidence else None,
            "rows": evidence.get("rows") if evidence else None,
            "error": evidence.get("error") if evidence else process.stderr[-2000:],
            "newCrashes": new_crashes,
            "screenshots": [
                str(data / name) for name in (evidence.get("screenshots") or [])
            ] if evidence else [],
        }, indent=2))
        if process.stderr:
            print(process.stderr[-2000:])
        server.shutdown()
        if process.returncode or not evidence or not evidence.get("passed") or new_crashes:
            raise SystemExit(1)


if __name__ == "__main__":
    main()
