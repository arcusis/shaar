#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Prove the 3D stacking view in a hidden shipping-bundle window."""

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


PAGE = """<!doctype html>
<meta charset="utf-8">
<title>Stacking fixture</title>
<style>
  body { margin: 0; font: 16px sans-serif; }
  #page { position: relative; width: 640px; height: 420px; background: white; }
  #behind { position: absolute; left: 24px; top: 24px; width: 220px; height: 120px;
    z-index: -1; background: #e11d48; }
  #card { position: absolute; left: 70px; top: 70px; width: 260px; height: 150px;
    background: #e2e8f0; }
  #modal { position: absolute; left: 140px; top: 110px; width: 240px; height: 140px;
    z-index: 10; background: #2563eb; color: white; }
  #faded { opacity: 0.45; width: 160px; height: 48px; margin: 280px 0 0 24px; background: #0f766e; }
</style>
<body>
  <div id="page">
    <div id="behind">Behind</div>
    <div id="card">Card</div>
    <div id="modal">Modal</div>
    <div id="faded">Faded</div>
  </div>
</body>
"""


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGE.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *args):
        pass


@contextmanager
def disposable_root():
    root = Path(tempfile.mkdtemp(prefix="shaar-stacking-probe-"))
    try:
        yield root
    finally:
        shutil.rmtree(root, ignore_errors=True)


def crash_names(home):
    directory = home / "Library" / "Logs" / "DiagnosticReports"
    if not directory.is_dir():
        return set()
    names = set()
    for name in os.listdir(directory):
        lowered = name.lower()
        relevant = "arcusis" in lowered or "shaar" in lowered or "chromium" in lowered
        report = lowered.endswith(".ips") or lowered.endswith(".crash")
        if relevant and report:
            names.add(name)
    return names


def run_page(executable, page, root, label):
    home = root / f"home-{label}"
    home.mkdir()
    report_path = root / f"{label}.json"
    environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home))
    environment.pop("SHAAR_ENGINE_TESTING", None)
    result = subprocess.run(
        [str(executable), "--stacking-probe", str(report_path), page],
        env=environment, capture_output=True, text=True, timeout=180, check=False,
    )
    report = json.loads(report_path.read_text()) if report_path.exists() else {}
    return {
        "exitCode": result.returncode,
        "report": report,
        "stderrTail": result.stderr[-2000:],
        "screenshot": root / "stacking.png",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--site", default="https://example.com")
    options = parser.parse_args()
    executable = options.app / "Contents/MacOS/ArcusisBrowser"
    if not executable.is_file():
        parser.error(f"App executable is missing: {executable}")
    crashes_before = crash_names(Path.home())
    with ThreadingHTTPServer(("127.0.0.1", 0), Page) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        page = f"http://127.0.0.1:{server.server_port}/stacking"
        with disposable_root() as root:
            fixture = run_page(executable, page, root, "fixture")
            if fixture["screenshot"].is_file():
                options.receipt.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(
                    fixture["screenshot"], options.receipt.parent / "stacking-shipping.png")
            site = run_page(executable, options.site, root, "site")
            if site["screenshot"].is_file():
                options.receipt.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(site["screenshot"], options.receipt.parent / "stacking-site.png")
            new_crashes = sorted(crash_names(Path.home()) - crashes_before)
            receipt = {
                "fixture": {key: fixture[key] for key in ("exitCode", "report", "stderrTail")},
                "site": {key: site[key] for key in ("exitCode", "report", "stderrTail")},
                "siteURL": options.site,
                "newCrashReports": new_crashes,
            }
            options.receipt.parent.mkdir(parents=True, exist_ok=True)
            options.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
            print(json.dumps(receipt, indent=2))
            fixture_ok = fixture["exitCode"] == 0 and fixture["report"].get("passed") is True
            site_ok = site["exitCode"] == 0 and site["report"].get("passed") is True
            if not fixture_ok or not site_ok or new_crashes:
                raise SystemExit(1)


if __name__ == "__main__":
    main()
