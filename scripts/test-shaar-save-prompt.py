#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Exercise password, card, and address save prompts in a hidden verification bundle."""

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
BUTTON = (
    '<button id="plain" type="submit" '
    'style="position:fixed;left:8px;top:8px;width:180px;height:48px">'
)


class Fixture(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length:
            self.rfile.read(min(length, 65536))
        self.path = "/saved"
        self.do_GET()

    def do_GET(self):
        page = self.path.split("?", 1)[0]
        if page == "/password":
            body = f"""<!doctype html><meta charset="utf-8"><title>Password</title>
<form action="/saved" method="post">
<input name="username" autocomplete="username" value="parity-user">
<input name="password" type="password" autocomplete="current-password" value="parity-secret">
{BUTTON}Sign in</button></form>"""
        elif page == "/login":
            body = """<!doctype html><meta charset="utf-8"><title>Login</title>
<form>
<input id="username" name="username" autocomplete="username">
<input id="password" name="password" type="password" autocomplete="current-password">
</form>"""
        elif page == "/card":
            body = f"""<!doctype html><meta charset="utf-8"><title>Card</title>
<form action="/saved" method="post">
<input name="cc-name" autocomplete="cc-name" value="Parity Probe">
<input name="cc-number" autocomplete="cc-number" value="4111111111111111">
<input name="cc-exp" autocomplete="cc-exp" value="12/30">
{BUTTON}Pay</button></form>"""
        elif page == "/address":
            body = f"""<!doctype html><meta charset="utf-8"><title>Address</title>
<form action="/saved" method="post">
<input name="name" autocomplete="name" value="Parity Probe">
<input name="street-address" autocomplete="street-address" value="1 Loopback Road">
<input name="address-level2" autocomplete="address-level2" value="Local">
<input name="postal-code" autocomplete="postal-code" value="00000">
<input name="email" autocomplete="email" value="parity@localhost">
{BUTTON}Save address</button></form>"""
        elif page == "/saved":
            body = "<!doctype html><title>Saved</title><main>submitted</main>"
        else:
            self.send_error(404)
            return
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *args):
        return


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
    parser.add_argument("--receipt", type=Path, default=ROOT / "build/save-prompt/receipt.json")
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
            page = f"http://127.0.0.1:{server.server_address[1]}"
            environment = os.environ.copy()
            environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home),
                               SHAAR_ENGINE_TESTING="1", SHAAR_MOCK_KEYCHAIN="1")
            result = subprocess.run(
                [str(executable), "--save-prompt-probe", str(report_path), page],
                env=environment, capture_output=True, text=True, timeout=180, check=False,
            )
            report = json.loads(report_path.read_text()) if report_path.is_file() else {}
        finally:
            shutil.rmtree(root, ignore_errors=True)
        server.shutdown()
    crashes = sorted(crash_names() - before)
    receipt = {
        "verificationExecutable": str(executable), "exitCode": result.returncode,
        "allWindowsHidden": report.get("allWindowsHidden"),
        "windowsOnScreen": report.get("windowsOnScreen"),
        "rows": report.get("rows", []), "crashReports": crashes,
        "passed": result.returncode == 0 and report.get("passed") is True and not crashes,
    }
    options.receipt.parent.mkdir(parents=True, exist_ok=True)
    options.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))
    if not receipt["passed"]:
        if result.stderr:
            print(result.stderr[-4000:])
        raise SystemExit(1)


if __name__ == "__main__":
    main()
