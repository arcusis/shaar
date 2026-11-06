#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Measure a hidden Shaar verification bundle against authored loopback pages."""

import argparse
import http.server
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import threading
import time


class FixtureHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = (
            "<!doctype html><meta charset=utf-8><title>Shaar perf fixture</title>"
            "<main>Fixed local performance fixture</main>"
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


def process_rows():
    output = subprocess.check_output(["ps", "-axo", "pid=,ppid=,rss=,time="], text=True)
    rows = {}
    for line in output.splitlines():
        parts = line.split()
        if len(parts) == 4:
            pid, ppid, rss, cpu_time = parts
            fields = cpu_time.split(":")
            if len(fields) == 3:
                hours, minutes, seconds = fields
                cpu_seconds = (
                    int(hours) * 3600 + int(minutes) * 60 + float(seconds)
                )
            else:
                minutes, seconds = fields
                cpu_seconds = int(minutes) * 60 + float(seconds)
            rows[int(pid)] = (int(ppid), int(rss), cpu_seconds)
    return rows


def process_tree(root_pid):
    rows = process_rows()
    members = {root_pid}
    changed = True
    while changed:
        changed = False
        for pid, (ppid, _rss, _cpu) in rows.items():
            if ppid in members and pid not in members:
                members.add(pid)
                changed = True
    return [(pid, rows[pid]) for pid in members if pid in rows]


def measure_case(executable, port, tab_count, sample_seconds):
    with tempfile.TemporaryDirectory(prefix="arcusis-engine-probe-") as temporary:
        root = Path(temporary)
        (root / ".arcusis-probe").write_text("arcusis-engine-probe-v1\n")
        report = root / "initial.json"
        command = [
            str(executable), "--probe-data-dir", str(root),
            "--probe-url", f"http://127.0.0.1:{port}/page-1",
            "--probe-phase", "initial", "--probe-output", str(report),
            "--probe-measure-tabs", str(tab_count), "--probe-measure-seconds",
            str(sample_seconds + 8),
        ]
        started = time.monotonic()
        process = subprocess.Popen(
            command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
            start_new_session=True,
        )
        deadline = started + 150
        try:
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    error = process.stderr.read().decode(errors="replace")[-3000:]
                    raise RuntimeError(f"probe exited {process.returncode}: {error}")
                if report.exists():
                    break
                time.sleep(0.05)
            else:
                raise TimeoutError(f"{tab_count}-tab probe did not become ready")
            ready = json.loads(report.read_text())
            if ready.get("tabs") != tab_count:
                raise RuntimeError(f"unexpected readiness report: {ready}")
            cold_seconds = time.monotonic() - started
            rss_samples, cpu_samples, process_samples = [], [], []
            sample_end = time.monotonic() + sample_seconds
            previous_time = time.monotonic()
            previous_cpu = sum(
                row[2] for _pid, row in process_tree(process.pid)
            )
            while time.monotonic() < sample_end:
                tree = process_tree(process.pid)
                now = time.monotonic()
                rss_samples.append(sum(row[1] for _pid, row in tree) / 1024)
                process_samples.append(len(tree))
                cpu = sum(row[2] for _pid, row in tree)
                elapsed = max(0.001, now - previous_time)
                cpu_samples.append(max(0.0, cpu - previous_cpu) / elapsed * 100)
                previous_time, previous_cpu = now, cpu
                time.sleep(1)
            return {
                "tabs": tab_count,
                "coldLaunchToAllPagesReadySeconds": round(cold_seconds, 3),
                "processTreeRSSMiBMean": round(sum(rss_samples) / len(rss_samples), 1),
                "processTreeRSSMiBMin": round(min(rss_samples), 1),
                "processTreeRSSMiBMax": round(max(rss_samples), 1),
                "processTreeCountMean": round(sum(process_samples) / len(process_samples), 1),
                "idleCPUPercentMean": round(sum(cpu_samples) / len(cpu_samples), 2),
                "samples": len(rss_samples),
            }
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, default=Path("build/Shaar Verification.app"))
    parser.add_argument(
        "--output", type=Path, default=Path("build/performance-baseline.json")
    )
    parser.add_argument("--sample-seconds", type=int, default=15)
    args = parser.parse_args()
    executable = args.app / "Contents/MacOS/ShaarVerification"
    if not executable.is_file():
        raise SystemExit(f"verification executable not found: {executable}")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        cases = [measure_case(executable, server.server_port, count, args.sample_seconds)
                 for count in (1, 10, 30)]
    finally:
        server.shutdown()
        server.server_close()
    result = {
        "schema": 1,
        "scope": "Hidden verification app; fixed loopback fixture; app and descendant process RSS",
        "appBundleBytes": int(
            subprocess.check_output(["du", "-sk", str(args.app)], text=True).split()[0]
        ) * 1024,
        "engineFrameworkBytes": int(
            subprocess.check_output(
                [
                    "du", "-sk",
                    str(args.app / "Contents/Frameworks/Chromium Framework.framework"),
                ],
                text=True,
            ).split()[0]
        ) * 1024,
        "cases": cases,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
