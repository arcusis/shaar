"""Run the real native engine against a disposable, authored local account fixture."""

import http.server
import argparse
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import tempfile
import threading


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"""<!doctype html><html data-arcusis-fixture="v1"><meta charset="utf-8">
<title>Arcusis account isolation fixture</title>
<style>body{font:18px system-ui;padding:60px;color:#293445;background:#f0f4f8}</style>
<h1>Local account isolation fixture</h1><p>Disposable test data only.</p>
<form><label>Username <input id="username" autocomplete="username"></label>
<label>Password <input id="password" type="password" autocomplete="current-password"></label></form>
<script>window.arcusisInstance=crypto.randomUUID();</script></html>"""
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bitwarden", action="store_true", help="Install Bitwarden from the real Chrome Web Store in a disposable profile")
    options = parser.parse_args()
    root = Path(tempfile.mkdtemp(prefix="arcusis-engine-probe-"))
    (root / ".arcusis-probe").write_text("arcusis-engine-probe-v1\n")
    shutil.copytree("Tests/Fixtures/ProfileExtension", root / "Extension")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    executable = Path("build/Arcusis Browser.app/Contents/MacOS/ArcusisBrowser").resolve()
    print(f"Probe evidence: {root}", flush=True)
    failures = []
    try:
        for phase in ("initial", "restart"):
            output = root / f"{phase}.json"
            arguments = [str(executable), "--engine-probe", "--probe-data-dir", str(root),
                         "--probe-url", f"http://127.0.0.1:{server.server_port}/account",
                         "--probe-phase", phase, "--probe-output", str(output)]
            if options.bitwarden:
                arguments.append("--bitwarden")
            with (root / f"{phase}.log").open("w") as log:
                process = subprocess.Popen(arguments, stdout=log, stderr=log, start_new_session=True)
                try:
                    code = process.wait(timeout=170 if options.bitwarden else 90)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                    raise RuntimeError(f"{phase} timed out; see {root}/{phase}.log")
            if not output.exists():
                raise RuntimeError(f"{phase} failed ({code}); see {root}/{phase}.log")
            report = json.loads(output.read_text())
            if code != 0 or not report["passed"]:
                failure = f"{phase}: {report.get('error') or f'process exit {code}'}"
                failures.append(failure)
                print(f"FAILED {failure}", flush=True)
                if options.bitwarden and report.get("localFixturesPassed") and (root / f"{phase}-bitwarden.json").exists():
                    # Preserve cold-install failure while also collecting restart evidence.
                    continue
                raise RuntimeError(failure)
            print(f"{phase}: {len(report['checks'])} checks passed; Chromium {report['chromiumVersion']}", flush=True)
        if failures:
            raise RuntimeError("; ".join(failures))
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
