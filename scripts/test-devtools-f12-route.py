#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Prove F12 and Option-Command-I open the Chromium dock in the hidden verification harness."""

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

PAGE = """<!doctype html><meta charset="utf-8"><title>Shaar F12 route</title>
<main id="marker">F12 route fixture</main>"""


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/f12-route":
            self.send_error(404)
            return
        data = PAGE.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *args):
        pass


def painted(path):
    """Hidden Chromium views often cache a solid black bitmap. Skip those."""
    data = path.read_bytes()
    return len(data) > 20_000 and len(set(data)) > 150


def text_of(value):
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    return value


def load_report(path):
    if not path.is_file():
        return {}
    try:
        loaded = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}
    return loaded if isinstance(loaded, dict) else {}


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


def receipt_output_path(value: str) -> Path:
    path = Path(value)
    if path.is_symlink():
        raise argparse.ArgumentTypeError(f"receipt output must not be a symlink: {path}")
    if path.parent.is_symlink():
        raise argparse.ArgumentTypeError(f"receipt output parent must not be a symlink: {path.parent}")
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "build/Shaar Verification.app")
    parser.add_argument("--receipt", type=receipt_output_path,
                        default=ROOT / "build/devtools-f12-route/receipt.json")
    options = parser.parse_args()
    executable = options.app / "Contents/MacOS/ShaarVerification"
    if not executable.is_file():
        parser.error(f"Missing verification app: {executable}")
    before = crash_names()
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        root = Path(tempfile.mkdtemp(prefix="arcusis-engine-probe-"))
        result = None
        report = {}
        shots = {}
        timed_out = False
        stderr = ""
        try:
            marker = root / ".arcusis-probe"
            marker.write_text("arcusis-engine-probe-v1\n")
            marker.chmod(0o600)
            home = root / "home"
            home.mkdir()
            report_path = root / "report.json"
            page = f"http://127.0.0.1:{server.server_port}/f12-route"
            environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home))
            environment["SHAAR_ENGINE_TESTING"] = "1"
            try:
                result = subprocess.run(
                    [
                        str(executable), "--devtools-f12-route", str(report_path), page,
                        "--probe-data-dir", str(root),
                    ],
                    env=environment, capture_output=True, text=True, timeout=180, check=False,
                )
                stderr = text_of(result.stderr)
            except subprocess.TimeoutExpired as expired:
                timed_out = True
                stderr = text_of(expired.stderr)
            report = load_report(report_path)
            evidence = ROOT / "Evidence/issue-1469"
            evidence.mkdir(parents=True, exist_ok=True)
            for name in ("f12", "option-command-i"):
                source = root / f"{name}.png"
                if source.is_file() and painted(source):
                    destination = evidence / f"{name}-chromium-dock.png"
                    shutil.copyfile(source, destination)
                    shots[name] = str(destination.relative_to(ROOT))
        finally:
            shutil.rmtree(root, ignore_errors=True)
        server.shutdown()
    crashes = sorted(crash_names() - before)
    exit_code = None if timed_out or result is None else result.returncode
    receipt = {
        "verificationExecutable": str(executable), "exitCode": exit_code, "timedOut": timed_out,
        "allWindowsHidden": report.get("allWindowsHidden"),
        "rows": report.get("rows", []), "snapshots": shots, "crashReports": crashes,
        "passed": (
            not timed_out and result is not None and result.returncode == 0
            and report.get("passed") is True and not crashes
        ),
    }
    options.receipt.parent.mkdir(parents=True, exist_ok=True)
    options.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))
    if not receipt["passed"]:
        if stderr:
            print(stderr[-4000:])
        raise SystemExit(1)


if __name__ == "__main__":
    main()
