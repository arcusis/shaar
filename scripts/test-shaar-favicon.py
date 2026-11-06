#!/usr/bin/env python3
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


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
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
            home = root / "home"
            home.mkdir()
            report = root / "report.json"
            framework = app / "Contents/Frameworks/Chromium Framework.framework"
            command = [str(app / "Contents/MacOS/ShaarVerification"),
                       "--probe-shaar-first-tab", "--probe-framework", str(framework),
                       "--probe-output", str(report), "--probe-data-dir", str(data),
                       "--probe-favicon-url", f"http://127.0.0.1:{server.server_port}/"]
            environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home),
                               SHAAR_ENGINE_TESTING="1", RUNNER_TEMP=str(root))
            process = subprocess.run(command, env=environment, capture_output=True,
                                     text=True, timeout=35, check=False)
            if process.returncode or not report.exists():
                raise AssertionError(
                    f"favicon probe exit={process.returncode}: {process.stderr[-2500:]} "
                    f"report={report.read_text() if report.exists() else 'missing'}")
            result = json.loads(report.read_text())
            assert (result["passed"] and result["faviconObserved"]
                    and result["faviconCacheRestored"]
                    and result["inactiveFaviconObserved"]
                    and result["allWindowsHidden"]), result
            print(json.dumps({"exitCode": process.returncode, "faviconObserved": True,
                              "faviconCacheRestored": True,
                              "inactiveFaviconObserved": True,
                              "allWindowsHidden": True}, indent=2))
        server.shutdown()


if __name__ == "__main__":
    main()
