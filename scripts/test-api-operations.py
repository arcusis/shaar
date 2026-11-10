#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Prove GraphQL and tRPC operation names in the shipping Network panel."""

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
from urllib.parse import urlparse


PAGE = b"""<!doctype html><html><head><meta charset="utf-8"><title>API operations</title>
</head><body><p>Ready</p></body></html>
"""
GRAPHQL_ERROR = b'{"data":null,"errors":[{"message":"Cannot query field"}]}'
GRAPHQL_OK = b'{"data":{"__typename":"Query"}}'
TRPC_OK = b'{"result":{"data":[]}}'
TRPC_ERROR = b'{"error":{"json":{"message":"nope"}}}'


class Page(BaseHTTPRequestHandler):
    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "content-type")
        self.end_headers()

    def do_GET(self):
        path = urlparse(self.path).path
        if path in {"/", "/index.html"}:
            self.respond(PAGE, "text/html; charset=utf-8")
            return
        if path == "/graphql":
            self.respond(GRAPHQL_OK, "application/json")
            return
        if path == "/api/trpc/post.list":
            self.respond(TRPC_OK, "application/json")
            return
        self.respond(b"missing", "text/plain", status=404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length:
            self.rfile.read(length)
        path = urlparse(self.path).path
        if path == "/graphql":
            self.respond(GRAPHQL_ERROR, "application/json")
            return
        if path == "/api/trpc/post.create":
            self.respond(TRPC_ERROR, "application/json")
            return
        self.respond(b"missing", "text/plain", status=404)

    def respond(self, body, content_type, status=200):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
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
    prefixes = ("ArcusisBrowser", "Shaar", "Chromium")
    return sorted(name for name in names if name.startswith(prefixes))


@contextmanager
def disposable_root():
    root = Path(tempfile.mkdtemp(prefix="shaar-api-operations-"))
    try:
        yield root
    finally:
        shutil.rmtree(root, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    options = parser.parse_args()
    executable = options.app / "Contents/MacOS/ArcusisBrowser"
    if not executable.is_file():
        parser.error(f"App executable is missing: {executable}")
    before = crash_names()
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
            try:
                result = subprocess.run(
                    [str(executable), "--api-operations-probe", str(report_path), page],
                    env=environment, capture_output=True, text=True, timeout=240, check=False,
                )
            except subprocess.TimeoutExpired as error:
                result = subprocess.CompletedProcess(
                    [str(executable)], 124, "", f"timed out after 240s {error}")
            report = json.loads(report_path.read_text()) if report_path.is_file() else {}
            crashes = relevant(crash_names() - before)
            shots = []
            options.receipt.parent.mkdir(parents=True, exist_ok=True)
            for path in root.glob("*.png"):
                destination = options.receipt.parent / path.name
                shutil.copy2(path, destination)
                shots.append(destination.name)
            receipt = {
                "exitCode": result.returncode,
                "report": report,
                "screenshots": shots,
                "crashes": crashes,
                "stderrTail": (result.stderr or "")[-2000:],
            }
            text = json.dumps(receipt, indent=2) + "\n"
            options.receipt.write_text(text)
            print(text)
            leaked = "do-not-keep" in text
            if (
                result.returncode
                or leaked
                or crashes
                or report.get("passed") is not True
                or report.get("allWindowsHidden") is not True
                or report.get("publicContinents") is not True
                or report.get("screenshot") is not True
                or "network-operations.png" not in shots
            ):
                raise SystemExit(1)
        server.shutdown()


if __name__ == "__main__":
    main()
