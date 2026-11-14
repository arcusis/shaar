#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Prove a page title cannot open the share sheet, and a bound request can."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import tempfile
import threading


ROOT = Path(__file__).resolve().parents[1]
CRASHES = Path.home() / "Library/Logs/DiagnosticReports"
PAGE = """<!doctype html>
<meta charset="utf-8">
<title>Web share</title>
<p>Share sheet fixture</p>
"""


def write_receipt(path: Path, receipt: dict) -> None:
    if path.is_symlink():
        raise ValueError(f"web-share receipt path must not be a symlink: {path}")
    if path.exists() and not path.is_file():
        raise ValueError(f"web-share receipt path is not a regular file: {path}")
    write_output(path, (json.dumps(receipt, indent=2) + "\n").encode())


def copy_screenshot(source: Path, destination: Path) -> None:
    write_screenshot(destination, source.read_bytes())


def write_screenshot(destination: Path, data: bytes) -> None:
    if destination.is_symlink():
        raise ValueError(f"web-share screenshot path must not be a symlink: {destination}")
    if destination.exists() and not destination.is_file():
        raise ValueError(f"web-share screenshot path is not a regular file: {destination}")
    write_output(destination, data)


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?", 1)[0] != "/share":
            self.send_error(404)
            return
        body = PAGE.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        return


def crash_names():
    names = set()
    for directory in (CRASHES, CRASHES / "Retired"):
        if not directory.is_dir():
            continue
        names.update(
            path.name for path in directory.iterdir()
            if path.suffix in {".ips", ".crash"}
            and path.name.startswith(("Shaar", "ArcusisBrowser", "Chromium"))
        )
    return names


def validate_output_destination(path):
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        return
    if stat.S_ISLNK(mode):
        raise ValueError(f"Refusing symlink output: {path}")


def write_output(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags, 0o666)
    with os.fdopen(descriptor, "wb") as output:
        output.write(data)


def read_probe_file(path):
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    with os.fdopen(descriptor, "rb") as source:
        return source.read()


def run_probe(command, environment, timeout):
    try:
        process = subprocess.Popen(
            command, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, start_new_session=True)
    except OSError as error:
        return subprocess.CompletedProcess(command, 126, "", str(error))

    def text_output(value):
        if isinstance(value, bytes):
            return value.decode("utf-8", errors="replace")
        return value or ""

    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        stdout, stderr = process.communicate()
        return subprocess.CompletedProcess(
            command, 124, text_output(stdout), text_output(stderr))
    return subprocess.CompletedProcess(
        command, process.returncode, text_output(stdout), text_output(stderr))


def read_evidence(path):
    try:
        return json.loads(read_probe_file(path))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "build/Shaar Verification.app")
    parser.add_argument("--receipt", type=Path, default=ROOT / "build/web-share/receipt.json")
    options = parser.parse_args()
    screenshot = options.receipt.parent / "share-sheet.png"
    try:
        validate_output_destination(options.receipt)
        validate_output_destination(screenshot)
    except ValueError as error:
        parser.error(str(error))
    executable = options.app / "Contents/MacOS/ShaarVerification"
    framework = options.app / "Contents/Frameworks/Chromium Framework.framework"
    if not executable.is_file():
        parser.error(f"Missing verification app: {executable}")
    before = crash_names()
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        with tempfile.TemporaryDirectory(prefix="arcusis-engine-probe-") as temporary:
            root = Path(temporary)
            marker = root / ".arcusis-probe"
            marker.write_text("arcusis-engine-probe-v1\n")
            marker.chmod(0o600)
            home = root / "home"
            home.mkdir()
            report = root / "report.json"
            page = f"http://127.0.0.1:{server.server_port}/share"
            environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home),
                               SHAAR_ENGINE_TESTING="1", SHAAR_MOCK_KEYCHAIN="1")
            process = run_probe(
                [str(executable), "--probe-web-share",
                 "--probe-framework", str(framework),
                 "--probe-output", str(report), "--probe-data-dir", str(root),
                 "--probe-url", page], environment, timeout=90)
            evidence = read_evidence(report) if report.is_file() else None
            source = root / "share-sheet.png"
            try:
                screenshot_data = read_probe_file(source)
            except OSError:
                screenshot_data = None
            shots = {"share-sheet.png": screenshot_data is not None}
            if evidence and evidence.get("passed") and screenshot_data is not None:
                write_screenshot(screenshot, screenshot_data)
        server.shutdown()
    crashes = sorted(crash_names() - before)
    receipt = {
        "verificationExecutable": str(executable),
        "exitCode": process.returncode,
        "report": evidence,
        "screenshots": shots,
        "crashReports": crashes,
        "stderrTail": process.stderr[-4000:],
        "passed": process.returncode == 0 and bool(evidence and evidence.get("passed"))
        and all(shots.values()) and not crashes,
    }
    write_receipt(options.receipt, receipt)
    print(json.dumps({key: receipt[key] for key in (
        "exitCode", "passed", "screenshots", "crashReports")}, indent=2))
    if evidence:
        print(json.dumps({"checks": evidence.get("checks"), "error": evidence.get("error"),
                          "outcome": evidence.get("outcome")}, indent=2))
    if not receipt["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
