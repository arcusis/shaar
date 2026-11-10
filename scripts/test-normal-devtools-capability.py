#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Check the live DevTools lease in the normal hidden Preview bundle."""

import argparse
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import threading


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"<!doctype html><title>DevTools capability</title><p>Ready</p>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *args):
        pass


@contextmanager
def disposable_root():
    root = Path(tempfile.mkdtemp(prefix="shaar-normal-devtools-"))
    try:
        yield root
    finally:
        shutil.rmtree(root, ignore_errors=True)


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
                [str(executable), "--devtools-capability-probe", str(report_path), page],
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
            if (
                result.returncode
                or not report.get("allWindowsHidden")
                or report.get("normalBundle") not in {
                    "com.arcusis.browser", "com.arcusis.browser.engine-preview"
                }
                or not report.get("streamAvailable")
                or not report.get("phase2Available")
            ):
                raise SystemExit(1)
        server.shutdown()


if __name__ == "__main__":
    main()
