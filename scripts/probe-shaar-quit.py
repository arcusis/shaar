#!/usr/bin/env python3
"""Run hidden Shaar quit probes with fresh data roots and a local HTTP fixture."""

import argparse
import http.server
import json
import pathlib
import subprocess
import tempfile
import threading


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
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
    args = [
        str(app / "Contents/MacOS/ShaarVerification"),
        "--probe-shaar-preview",
        "--shaar-engine-backend=shaar",
        "--probe-output", str(report_path),
        "--probe-data-dir", str(root / "data"),
        "--probe-framework", str(app / "Contents/Frameworks/Chromium Framework.framework"),
    ]
    if mode == "pending":
        args += ["--probe-pending-quit-url", f"http://127.0.0.1:{port}/stall"]
    else:
        args += ["--probe-direct-quit", "--probe-download-url",
                 f"http://127.0.0.1:{port}/download/preview.txt"]
    try:
        result = subprocess.run(args, capture_output=True, timeout=timeout, check=False)
        return_code = result.returncode
        stderr = result.stderr
    except subprocess.TimeoutExpired as error:
        return_code = "timeout"
        stderr = error.stderr or b""
    (root / "stderr.log").write_bytes(stderr)
    report = json.loads(report_path.read_text()) if report_path.exists() else {}
    results = report.get("results", {})
    if mode == "pending":
        required = {"openTab", "pendingNavigation"}
    else:
        required = {
            "openTab", "navigate", "backForward", "devTools", "newWindow",
            "privateWindow", "profilesSwitch", "extensions", "downloads",
        }
    passed = (
        return_code == 0
        and report.get("passed") is True
        and report.get("allWindowsHidden") is True
        and report.get("visibleWindowEvidence") == []
        and set(results) == required
        and all(item.get("status") == "pass" for item in results.values())
    )
    print(f"{mode} {number}: {'PASS' if passed else 'FAIL'} "
          f"(exit={return_code}, checks={len(results)}, report={report_path})", flush=True)
    return passed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path,
                        default=pathlib.Path("build/Shaar Verification.app"))
    parser.add_argument("--runs", type=int, default=6)
    parser.add_argument("--timeout", type=int, default=30)
    parser.add_argument("--output-dir", type=pathlib.Path)
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
            for mode in ("pending", "private-live")
            for number in range(1, options.runs + 1)
        ]
    finally:
        server.stop_event.set()
        server.shutdown()
        server.server_close()
        thread.join()
    print(f"Results: {sum(outcomes)}/{len(outcomes)}; evidence: {output_dir}")
    return 0 if all(outcomes) else 1


if __name__ == "__main__":
    raise SystemExit(main())
