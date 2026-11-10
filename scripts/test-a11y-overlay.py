#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Prove the focus-order and contrast overlay in the shipping app, hidden."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time


ROOT = Path(__file__).resolve().parents[1]
PAGE = b"""<!doctype html><html><head><meta charset="utf-8">
<title>Focus and contrast</title>
<style>
  body { margin: 24px; background: #fff; color: #111; font: 16px Arial, sans-serif; }
  button, a { margin-right: 12px; color: #111; background: #fff; }
  .fail { color: #777777; background: #fff; }
  .pass { color: #111; background: #fff; }
  .large { color: #777777; background: #fff; font-size: 24px; }
</style></head><body>
<button id="priority" tabindex="1">Priority</button>
<button id="one">First</button>
<a id="two" href="#next">Second</a>
<button id="skip" disabled>Skip</button>
<span id="minus" tabindex="-1">Minus</span>
<p class="fail">Low contrast</p>
<p class="pass">High contrast</p>
<p class="large">Large text</p>
</body></html>"""


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGE if self.path.split("?", 1)[0] == "/overlay" else b"missing"
        status = 200 if body != b"missing" else 404
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        pass


def crashes_since(started):
    root = Path.home() / "Library/Logs/DiagnosticReports"
    if not root.is_dir():
        return []
    found = []
    for path in root.iterdir():
        try:
            modified = path.stat().st_mtime
        except OSError:
            continue
        if modified < started:
            continue
        name = path.name.lower()
        if "shaar" in name or "arcusis" in name:
            found.append(path.name)
    return sorted(found)


def run_probe(executable, page, evidence):
    root = Path(tempfile.mkdtemp(prefix="shaar-a11y-overlay-"))
    home = root / "home"
    home.mkdir()
    report_path = root / "report.json"
    environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home))
    result = subprocess.run(
        [str(executable), "--a11y-overlay", str(report_path), page],
        env=environment, capture_output=True, text=True, timeout=240, check=False,
    )
    report = json.loads(report_path.read_text()) if report_path.exists() else {}
    saved = {}
    for name in ("panel-before.png", "panel-after.png", "page.png"):
        source = root / name
        if not source.is_file():
            continue
        destination = (evidence / name).resolve()
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        saved[name] = str(destination.relative_to(ROOT))
    stderr = result.stderr[-2000:]
    shutil.rmtree(root, ignore_errors=True)
    return {
        "exitCode": result.returncode,
        "report": report,
        "screenshots": saved,
        "stderrTail": stderr,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--evidence", required=True, type=Path)
    options = parser.parse_args()
    executable = options.app / "Contents/MacOS/ArcusisBrowser"
    if not executable.is_file():
        parser.error(f"App executable is missing: {executable}")
    options.evidence.mkdir(parents=True, exist_ok=True)
    started = time.time()
    with ThreadingHTTPServer(("127.0.0.1", 0), Page) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        local = run_probe(
            executable, f"http://127.0.0.1:{server.server_port}/overlay",
            options.evidence / "fixture")
        server.shutdown()
    world_dir = options.evidence / "example"
    world = run_probe(executable, "https://example.com/", world_dir)
    found = crashes_since(started)
    receipt = {"fixture": local, "example": world, "crashReports": found}
    receipt_path = options.evidence / "receipt.json"
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({
        "fixturePassed": local["report"].get("passed"),
        "fixtureSummary": local["report"].get("summary"),
        "fixtureFocus": local["report"].get("focus"),
        "fixtureContrast": local["report"].get("contrast"),
        "fixtureError": local["report"].get("error") or local["report"].get("failure"),
        "examplePassed": world["report"].get("passed"),
        "exampleSummary": world["report"].get("summary"),
        "exampleFocus": world["report"].get("focus"),
        "exampleError": world["report"].get("error") or world["report"].get("failure"),
        "crashReports": found,
    }, indent=2))
    if found or not local["report"].get("passed") or not world["report"].get("passed"):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
