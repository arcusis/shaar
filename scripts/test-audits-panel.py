#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Run the Audits panel in a hidden production bundle against a loopback page."""

import argparse
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time


PAGE = b"""<!doctype html>
<html lang="en">
<head><title>Audit fixture</title></head>
<body>
<button id="shaar-audit-unnamed"></button>
<img id="shaar-audit-image" src="/pixel.gif">
</body>
</html>
"""


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGE
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *args):
        pass


@contextmanager
def disposable_root():
    root = Path(tempfile.mkdtemp(prefix="shaar-audits-panel-"))
    try:
        yield root
    finally:
        shutil.rmtree(root, ignore_errors=True)


def crash_reports(started: float) -> list[str]:
    directory = Path.home() / "Library/Logs/DiagnosticReports"
    if not directory.is_dir():
        return []
    found = []
    for path in directory.iterdir():
        if path.suffix not in {".ips", ".crash"}:
            continue
        if path.stat().st_mtime < started:
            continue
        name = path.name.lower()
        if "shaar" in name or "arcusis" in name:
            found.append(path.name)
    return sorted(found)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    options = parser.parse_args()
    executable = options.app / "Contents/MacOS/ShaarVerification"
    if not executable.is_file():
        parser.error(f"Verification executable is missing: {executable}")
    with ThreadingHTTPServer(("127.0.0.1", 0), Page) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        with disposable_root() as root:
            home = root / "home"
            home.mkdir()
            report_path = root / "report.json"
            page = f"http://127.0.0.1:{server.server_port}/"
            environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home))
            environment.pop("SHAAR_ENGINE_TESTING", None)
            started = time.time()
            result = subprocess.run(
                [str(executable), "--audits-probe", str(report_path), page],
                env=environment, capture_output=True, text=True, timeout=180, check=False,
            )
            time.sleep(2)
            report = json.loads(report_path.read_text()) if report_path.exists() else {}
            crashes = crash_reports(started)
            receipt = {
                "exitCode": result.returncode,
                "report": report,
                "crashReports": crashes,
                "stderrTail": result.stderr[-2000:],
            }
            options.receipt.parent.mkdir(parents=True, exist_ok=True)
            options.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
            print(json.dumps(receipt, indent=2))
            rules = report.get("rules") or []
            if (
                result.returncode
                or crashes
                or not report.get("passed")
                or not report.get("allWindowsHidden")
                or not report.get("resourceBundleStaged")
                or report.get("section") != "Audits"
                or report.get("normalBundle") != "com.arcusis.browser"
                or "button-name" not in rules
                or "image-alt" not in rules
            ):
                raise SystemExit(1)
        server.shutdown()


if __name__ == "__main__":
    main()
