#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Run the hidden native favicon probe against an authored loopback page."""

import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import zlib


def png() -> bytes:
    def chunk(kind: bytes, body: bytes) -> bytes:
        data = kind + body
        return struct.pack(">I", len(body)) + data + struct.pack(">I", zlib.crc32(data))

    rows = b"".join(b"\0" + bytes((18, 91, 210, 255)) * 16 for _ in range(16))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 16, 16, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def copy_evidence(source: Path, destination: Path) -> None:
    if destination.is_symlink():
        raise ValueError(f"favicon evidence output must not be a symlink: {destination}")
    if destination.exists() and not destination.is_file():
        raise ValueError(f"favicon evidence output is not a regular file: {destination}")
    destination.write_bytes(source.read_bytes())


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        if self.path.startswith("/icon.png"):
            body, content_type = png(), "image/png"
        else:
            body = b'<html><head><title>Favicon fixture</title><link rel="icon" type="image/png" href="/icon.png"></head><body>Favicon fixture</body></html>'
            content_type = "text/html"
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args: object) -> None:
        pass


def run_probe(app: Path, root: Path, data: Path, report: Path, page: str,
              extra: list[str]) -> tuple[subprocess.CompletedProcess[str], dict]:
    framework = app / "Contents/Frameworks/Chromium Framework.framework"
    home = root / "home"
    command = [str(app / "Contents/MacOS/ShaarVerification"),
               "--probe-shaar-first-tab", "--probe-framework", str(framework),
               "--probe-output", str(report), "--probe-data-dir", str(data),
               "--probe-favicon-url", page, *extra]
    environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home),
                       SHAAR_ENGINE_TESTING="1", RUNNER_TEMP=str(root))
    process = subprocess.run(command, env=environment, capture_output=True,
                             text=True, timeout=60, check=False)
    evidence = Path("build/favicon-1045-evidence")
    evidence.mkdir(parents=True, exist_ok=True)
    sidebar = root / "favicon-sidebar.png"
    if sidebar.exists():
        copy_evidence(sidebar, evidence / f"{report.stem}.png")
    if report.exists():
        copy_evidence(report, evidence / report.name)
    if process.returncode or not report.exists():
        raise AssertionError(
            f"favicon probe exit={process.returncode}: {process.stderr[-2500:]} "
            f"report={report.read_text() if report.exists() else 'missing'}")
    return process, json.loads(report.read_text())


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
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        with tempfile.TemporaryDirectory(prefix="shaar-favicon-") as temporary:
            root = Path(temporary)
            data = root / "arcusis-engine-probe-favicon"
            data.mkdir(mode=0o700)
            marker = data / ".arcusis-probe"
            marker.write_text("arcusis-engine-probe-v1\n")
            marker.chmod(0o600)
            (root / "home").mkdir()
            page = f"http://127.0.0.1:{server.server_port}/"
            first_report = root / "report.json"
            _, first = run_probe(app, root, data, first_report, page, [])
            assert (first["passed"] and first["faviconObserved"]
                    and first["faviconCacheRestored"]
                    and first["inactiveFaviconObserved"]
                    and first["favoriteFaviconCached"]
                    and first["allWindowsHidden"]), first
            restore_report = root / "restore.json"
            _, restored = run_probe(
                app, root, data, restore_report, page, ["--probe-favicon-restore"])
            assert (restored["passed"] and restored["restoredPinIcon"]
                    and restored["restoredFavoriteIcon"]
                    and restored["restoredPinFromCache"]
                    and restored["restoredFavoriteDormant"]
                    and 640 <= restored["sidebarIconPixels"] <= 960
                    and restored["allWindowsHidden"]), restored
            evidence = Path("build/favicon-1045-evidence")
            evidence.mkdir(parents=True, exist_ok=True)
            sidebar = root / "favicon-sidebar.png"
            if sidebar.exists():
                copy_evidence(sidebar, evidence / "favicon-sidebar-after-relaunch.png")
            print(json.dumps({
                "exitCode": 0,
                "faviconObserved": True,
                "faviconCacheRestored": True,
                "inactiveFaviconObserved": True,
                "favoriteFaviconCached": True,
                "restoredPinIcon": True,
                "restoredFavoriteIcon": True,
                "restoredPinFromCache": True,
                "restoredFavoriteDormant": True,
                "sidebarIconPixels": restored["sidebarIconPixels"],
                "allWindowsHidden": True,
            }, indent=2))
        server.shutdown()


if __name__ == "__main__":
    main()
