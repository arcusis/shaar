#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Prove sensor overrides on the pinned engine, with no visible window."""

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


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"<!doctype html><title>Sensors probe</title><p>Ready</p>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *args):
        pass


@contextmanager
def disposable_root():
    root = Path(tempfile.mkdtemp(prefix="shaar-sensors-probe-"))
    try:
        yield root
    finally:
        shutil.rmtree(root, ignore_errors=True)


def proves_shaar20(report, code):
    french = str(report.get("frenchLocale", "")).lower()
    if code or report.get("error") or not report.get("allWindowsHidden"):
        return False
    if report.get("normalBundle") not in {
        "com.arcusis.browser", "com.arcusis.browser.engine-preview"
    }:
        return False
    if report.get("tokyoTimezone") != "Asia/Tokyo":
        return False
    if not french.startswith("fr"):
        return False
    if report.get("emptyTimezoneZone") != "Asia/Tokyo":
        return False
    if not report.get("emptyTimezoneError"):
        return False
    if report.get("emptyLocaleValue") != report.get("frenchLocale"):
        return False
    if not report.get("emptyLocaleError"):
        return False
    return report.get("idleMissing") is True


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
            result = subprocess.run(
                [str(executable), "--sensors-probe", str(report_path), page],
                env=environment, capture_output=True, text=True, timeout=120, check=False,
            )
            report = json.loads(report_path.read_text()) if report_path.exists() else {}
            receipt = {
                "exitCode": result.returncode,
                "report": report,
                "stderrTail": result.stderr[-2000:],
            }
            options.receipt.parent.mkdir(parents=True, exist_ok=True)
            options.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
            print(json.dumps(receipt, indent=2))
            if not proves_shaar20(report, result.returncode):
                raise SystemExit(1)
        server.shutdown()


if __name__ == "__main__":
    main()
