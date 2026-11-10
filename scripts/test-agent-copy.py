#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Prove the agent packet through the hidden verification harness."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading


PAGE = b"""<!doctype html><html><head><meta charset="utf-8"><title>Agent packet</title>
<style>
  #card { color: red; padding: 8px; width: 240px; height: 80px; }
  #card.special { color: blue; }
</style></head><body>
<div id="card" class="special" tabindex="0" data-source="/src/Card.tsx:12">
  <h1>Card title</h1>
  <input value="secret-value">
</div>
<script>
console.error("early-console-error");
fetch("/missing", {headers:{Authorization:"Bearer fixture-token"}})
  .finally(function () { window.__agentCopyReady = true; });
</script>
</body></html>"""


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in {"/card", "/card/"}:
            self.reply(200, PAGE, "text/html; charset=utf-8")
            return
        if path in {"/missing", "/missing-again"}:
            self.reply(404, b"not found", "text/plain; charset=utf-8", cookie=True)
            return
        self.reply(404, b"not found", "text/plain; charset=utf-8")

    def reply(self, status, body, content_type, cookie=False):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        if cookie:
            self.send_header("Set-Cookie", "secret=cookie-value")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *args):
        return


def crash_names():
    names = set()
    home = Path.home() / "Library/Logs/DiagnosticReports"
    for directory in (home, home / "Retired"):
        if not directory.is_dir():
            continue
        for path in directory.iterdir():
            if path.suffix in {".ips", ".crash"}:
                names.add(path.name)
    return names


def relevant(names):
    prefixes = ("ArcusisBrowser", "Shaar", "Chromium", "ShaarVerification")
    return sorted(name for name in names if name.startswith(prefixes))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, default=Path("build/Shaar Verification.app"))
    parser.add_argument("--receipt", type=Path, default=Path("build/agent-copy/receipt.json"))
    parser.add_argument("--screenshots", type=Path, default=None)
    options = parser.parse_args()
    app = options.app.resolve()
    executable = app / "Contents/MacOS/ShaarVerification"
    if not executable.is_file():
        parser.error(f"Verification app is missing: {app}")
    before = crash_names()
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        root = Path(tempfile.mkdtemp(prefix="shaar-agent-copy-"))
        try:
            home = root / "home"
            home.mkdir()
            report_path = root / "report.json"
            page = f"http://127.0.0.1:{server.server_port}/card"
            environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home))
            environment["SHAAR_MOCK_KEYCHAIN"] = "1"
            stdout_path = root / "stdout.txt"
            stderr_path = root / "stderr.txt"
            with stdout_path.open("w") as stdout_handle, stderr_path.open("w") as stderr_handle:
                try:
                    result = subprocess.run(
                        [str(executable), "--agent-copy-probe", str(report_path), page],
                        env=environment, stdout=stdout_handle, stderr=stderr_handle,
                        text=True, timeout=240, check=False,
                    )
                except subprocess.TimeoutExpired:
                    result = subprocess.CompletedProcess([str(executable)], 124, "", "timed out")
            report = json.loads(report_path.read_text()) if report_path.is_file() else {}
            crashes = relevant(crash_names() - before)
            if options.screenshots is not None:
                options.screenshots.mkdir(parents=True, exist_ok=True)
                for name in ("before.png", "after.png"):
                    source = root / name
                    if source.is_file():
                        shutil.copy2(source, options.screenshots / name)
                panels = Path("build/agent-copy-panels")
                if panels.is_dir():
                    for source in panels.glob("*.png"):
                        shutil.copy2(source, options.screenshots / source.name)
            options.receipt.parent.mkdir(parents=True, exist_ok=True)
            receipt = {
                "exitCode": result.returncode,
                "passed": report.get("passed") is True and not crashes and result.returncode == 0,
                "failures": report.get("failures", []),
                "panelInHierarchy": report.get("panelInHierarchy", False),
                "invokedCopy": report.get("invokedCopy", False),
                "bridgeInvoked": report.get("bridgeInvoked", False),
                "bridgeEnabled": report.get("bridgeEnabled", False),
                "bridgeError": report.get("bridgeError", ""),
                "allWindowsHidden": report.get("allWindowsHidden", False),
                "targetURL": report.get("targetURL", ""),
                "crashes": crashes,
                "stderrTail": stderr_path.read_text(errors="replace")[-2000:] if stderr_path.is_file() else "",
            }
            if not report_path.is_file():
                receipt["failures"] = [f"The verification app exited {result.returncode} without a report"]
                receipt["passed"] = False
            options.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
            print(json.dumps({k: receipt[k] for k in ("passed", "failures", "crashes", "exitCode", "bridgeError")}))
            if not receipt["passed"]:
                raise SystemExit(1)
        finally:
            shutil.rmtree(root, ignore_errors=True)
            server.shutdown()


if __name__ == "__main__":
    main()
