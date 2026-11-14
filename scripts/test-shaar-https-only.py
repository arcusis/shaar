#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Hidden proof that public HTTP upgrades, and that turning the setting off loads HTTP."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


CRASHES = Path.home() / "Library/Logs/DiagnosticReports"
MARKER = b"plain-http-loaded"


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path.split("?", 1)[0] != "/plain":
            self.send_error(404)
            return
        body = b"<html><head><title>Plain HTTP</title></head><body>" + MARKER + b"</body></html>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args: object) -> None:
        pass


def crash_names() -> set[str]:
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


def launch(app: Path, root: Path, url: str, *, upgrade: bool) -> dict:
    data = root / ("arcusis-engine-probe-https-on" if upgrade else "arcusis-engine-probe-https-off")
    data.mkdir(mode=0o700)
    marker = data / ".arcusis-probe"
    marker.write_text("arcusis-engine-probe-v1\n")
    marker.chmod(0o600)
    home = root / ("home-on" if upgrade else "home-off")
    home.mkdir()
    report = root / ("https-on.json" if upgrade else "https-off.json")
    framework = app / "Contents/Frameworks/Chromium Framework.framework"
    command = [
        str(app / "Contents/MacOS/ShaarVerification"),
        "--probe-https-only",
        "--probe-framework", str(framework),
        "--probe-output", str(report),
        "--probe-data-dir", str(data),
        "--probe-http-url", url,
    ]
    if not upgrade:
        command.append("--probe-https-only-off")
    environment = dict(
        os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home),
        SHAAR_ENGINE_TESTING="1", SHAAR_MOCK_KEYCHAIN="1", RUNNER_TEMP=str(root))
    process = subprocess.run(
        command, env=environment, capture_output=True, text=True, timeout=50, check=False)
    result = json.loads(report.read_text()) if report.exists() else {}
    result["exitCode"] = process.returncode
    if process.returncode or not result.get("passed"):
        result["stderr"] = process.stderr[-2500:]
    return result


def verification_app_path(value: str) -> Path:
    app = Path(value)
    executable = app / "Contents/MacOS/ShaarVerification"
    if not app.is_dir() or not executable.is_file():
        raise argparse.ArgumentTypeError(
            f"verification app is missing or incomplete: {app}")
    return app


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=verification_app_path)
    options = parser.parse_args()
    app = options.app.resolve()
    before = crash_names()
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        url = f"http://trackertest.org:{server.server_port}/plain"
        with tempfile.TemporaryDirectory(prefix="shaar-https-only-") as temporary:
            root = Path(temporary)
            upgraded = launch(app, root, url, upgrade=True)
            allowed = launch(app, root, url, upgrade=False)
        server.shutdown()
    new_crashes = sorted(crash_names() - before)
    first_open = ["Preferences"]
    if (
        new_crashes
        or not upgraded.get("passed")
        or not allowed.get("passed")
        or upgraded.get("profileFilesBeforeOpen") != first_open
        or allowed.get("profileFilesBeforeOpen") != first_open
    ):
        raise SystemExit(
            json.dumps({
                "upgraded": upgraded, "allowed": allowed, "newCrashes": new_crashes,
            }, indent=2))
    print(json.dumps({
        "upgraded": {key: upgraded.get(key) for key in (
            "passed", "href", "seededHttpsOnly", "profileFilesBeforeOpen", "allWindowsHidden")},
        "allowed": {key: allowed.get(key) for key in (
            "passed", "href", "seededHttpsOnly", "profileFilesBeforeOpen", "pageText",
            "allWindowsHidden")},
        "newCrashes": [],
    }, indent=2))


if __name__ == "__main__":
    main()
