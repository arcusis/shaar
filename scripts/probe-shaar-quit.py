#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Run hidden Shaar quit probes with fresh data roots and a local HTTP fixture."""

import argparse
import http.server
import json
import os
import pathlib
import subprocess
import tempfile
import threading


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/paint":
            payload = (b'<!doctype html><html><head><title>Paint fixture</title>'
                       b'<style>html,body{margin:0;width:100%;height:100%;'
                       b'background:#1678c6}</style></head><body></body></html>')
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/stall":
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(b"<html><body>pending")
            self.wfile.flush()
            self.server.stop_event.wait(120)
            return
        if self.path == "/download/preview.txt":
            payload = b"Shaar quit probe\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Disposition", 'attachment; filename="preview.txt"')
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_error(404)

    def log_message(self, format, *args):
        pass


def run_probe(app, output_dir, mode, number, port, timeout):
    root = output_dir / f"{mode}-{number}"
    root.mkdir(parents=True)
    report_path = root / "report.json"
    data_root = pathlib.Path(tempfile.mkdtemp(prefix="arcusis-engine-probe-"))
    marker = data_root / ".arcusis-probe"
    marker.write_text("arcusis-engine-probe-v1\n")
    marker.chmod(0o600)
    args = [
        str(app / "Contents/MacOS/ShaarVerification"),
        "--probe-shaar-preview",
        "--shaar-engine-backend=shaar",
        "--probe-output", str(report_path),
        "--probe-data-dir", str(data_root),
        "--probe-framework", str(app / "Contents/Frameworks/Chromium Framework.framework"),
    ]
    if mode in ("pending", "pending-private"):
        args += ["--probe-pending-quit-url", f"http://127.0.0.1:{port}/stall"]
        if mode == "pending-private":
            args.append("--probe-pending-private-quit")
    elif mode == "private-close-live":
        args.append("--probe-private-close-live")
    else:
        args += ["--probe-direct-quit", "--probe-download-url",
                 f"http://127.0.0.1:{port}/download/preview.txt",
                 "--probe-paint-url", f"http://127.0.0.1:{port}/paint"]
    try:
        result = subprocess.run(args, capture_output=True, timeout=timeout, check=False,
                                env=dict(os.environ, SHAAR_ENGINE_TESTING="1"))
        return_code = result.returncode
        stderr = result.stderr
    except subprocess.TimeoutExpired as error:
        return_code = "timeout"
        stderr = error.stderr or b""
    (root / "stderr.log").write_bytes(stderr)
    report = json.loads(report_path.read_text()) if report_path.exists() else {}
    results = report.get("results", {})
    if mode in ("pending", "pending-private"):
        required = {"openTab", "pendingNavigation"}
        if mode == "pending-private":
            required.add("privateWindow")
    elif mode == "private-close-live":
        required = {"openTab", "privateWindow", "privateWindowClose", "normalTabSurvives"}
    else:
        required = {
            "openTab", "paint", "navigate", "backForward", "devTools", "newWindow",
            "privateWindow", "profilesSwitch", "extensions", "downloads",
            "privateEngineProfileIsOffTheRecord", "privateEngineGlobalCookiesBlocked",
            "privateEngineHTTPSOnlyEnabled", "privateEngineReferrersDisabled",
            "privateEngineWebRTCPublicIPOnly", "privateEngineExtensionsDisabled",
            "privateEngineTrackerRulesLoaded",
        }
    passed = (
        return_code == 0
        and report.get("passed") is True
        and report.get("allWindowsHidden") is True
        and report.get("visibleWindowEvidence") == []
        and set(results) == required
        and all(item.get("status") == "pass" for item in results.values())
        and (mode != "pending-private"
             or report.get("diagnostics", {}).get("privateWindowLiveAtQuit") is True)
        and b"observers_.empty()" not in stderr
    )
    print(f"{mode} {number}: {'PASS' if passed else 'FAIL'} "
          f"(exit={return_code}, checks={len(results)}, report={report_path})", flush=True)
    return passed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path,
                        default=pathlib.Path("build/Shaar Verification.app"))
    parser.add_argument("--runs", type=int, default=6)
    parser.add_argument("--timeout", type=int, default=90)
    parser.add_argument("--output-dir", type=output_directory_path)
    parser.add_argument("--mode", action="append",
                        choices=("pending", "private-live", "pending-private",
                                 "private-close-live"),
                        help="Run only this mode; repeat to select several modes")
    options = parser.parse_args()
    if options.runs < 1 or options.timeout < 1:
        parser.error("--runs and --timeout must be positive")
    app = options.app.resolve()
    if not (app / "Contents/MacOS/ShaarVerification").is_file():
        parser.error(f"verification bundle is missing: {app}")
    output_dir = options.output_dir or pathlib.Path(tempfile.mkdtemp(prefix="shaar-quit-probe-"))
    output_dir.mkdir(parents=True, exist_ok=True)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture)
    server.daemon_threads = True
    server.stop_event = threading.Event()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        outcomes = [
            run_probe(app, output_dir, mode, number, server.server_port, options.timeout)
            for mode in (options.mode or ("pending", "private-live"))
            for number in range(1, options.runs + 1)
        ]
    finally:
        server.stop_event.set()
        server.shutdown()
        server.server_close()
        thread.join()
    print(f"Results: {sum(outcomes)}/{len(outcomes)}; evidence: {output_dir}")
    return 0 if all(outcomes) else 1


def output_directory_path(value):
    path = pathlib.Path(value)
    if path.is_symlink():
        raise argparse.ArgumentTypeError(f"output directory must not be a symlink: {path}")
    if path.parent.is_symlink():
        raise argparse.ArgumentTypeError(
            f"output directory parent must not be a symlink: {path.parent}")
    return path


if __name__ == "__main__":
    raise SystemExit(main())
