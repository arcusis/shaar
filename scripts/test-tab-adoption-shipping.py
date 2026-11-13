#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Exercise page-created tab adoption in a hidden Shaar Verification.app."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading


ROOT = Path(__file__).resolve().parents[1]
CRASHES = Path.home() / "Library/Logs/DiagnosticReports"


def write_receipt(path: Path, receipt: dict) -> None:
    if path.is_symlink():
        raise ValueError(f"tab adoption receipt path must not be a symlink: {path}")
    if path.exists() and not path.is_file():
        raise ValueError(f"tab adoption receipt path is not a regular file: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(receipt, indent=2) + "\n")


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        destination = f"http://localhost:{self.server.server_port}/cross-site-b"
        if self.path == "/cross-site-a":
            body = f'''<!doctype html><meta charset="utf-8"><title>Origin A</title>
<a id="blank" target="_blank" href="{destination}" onclick="document.documentElement.dataset.clicked='blank';document.documentElement.dataset.trusted=String(event.isTrusted)">New tab link</a>
<button id="popup" onclick="document.documentElement.dataset.clicked='popup';document.documentElement.dataset.trusted=String(event.isTrusted);window.open('{destination}', '_blank')">Open window</button>'''
        elif self.path == "/cross-site-b":
            body = '<!doctype html><title>Origin B</title><main id="destination">Cross-site destination loaded</main>'
        else:
            self.send_error(404)
            return
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
                and path.name.startswith(("Shaar", "ArcusisBrowser", "Chromium"))
            )
    return names


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "build/Shaar Verification.app")
    parser.add_argument("--receipt", type=Path, default=ROOT / "build/tab-adoption/receipt.json")
    options = parser.parse_args()
    executable = options.app / "Contents/MacOS/ShaarVerification"
    if not executable.is_file():
        parser.error(f"Missing verification app: {executable}")
    before = crash_names()
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        root = Path(tempfile.mkdtemp(prefix="arcusis-engine-probe-"))
        try:
            marker = root / ".arcusis-probe"
            marker.write_text("arcusis-engine-probe-v1\n")
            marker.chmod(0o600)
            home = root / "home"
            home.mkdir()
            report_path = root / "report.json"
            page = f"http://127.0.0.1:{server.server_port}/cross-site-a"
            environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home))
            environment["SHAAR_ENGINE_TESTING"] = "1"
            result = subprocess.run(
                [str(executable), "--tab-adoption-smoke", str(report_path), page],
                env=environment, capture_output=True, text=True, timeout=90, check=False,
            )
            report = json.loads(report_path.read_text()) if report_path.is_file() else {}
        finally:
            shutil.rmtree(root, ignore_errors=True)
        server.shutdown()
    crashes = sorted(crash_names() - before)
    receipt = {
        "verificationExecutable": str(executable), "exitCode": result.returncode,
        "allWindowsHidden": report.get("allWindowsHidden"),
        "rows": report.get("rows", []), "crashReports": crashes,
        "passed": result.returncode == 0 and report.get("passed") is True and not crashes,
    }
    write_receipt(options.receipt, receipt)
    print(json.dumps(receipt, indent=2))
    if not receipt["passed"]:
        if result.stderr:
            print(result.stderr[-4000:])
        raise SystemExit(1)


if __name__ == "__main__":
    main()
