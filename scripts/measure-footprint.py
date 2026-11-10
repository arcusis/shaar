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
import re
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


ALLOWED_TAB_COUNTS = (1, 10, 30, 50, 100)
WAIT_TRAPS = (
    "mach_msg_trap",
    "mach_msg2_trap",
    "semaphore_wait_trap",
    "semaphore_timedwait_trap",
    "__psynch_cvwait",
    "__psynch_mutexwait",
    "__ulock_wait",
    "swtch_pri",
    # kevent64, __psynch_cvwait, and __workq_kernreturn are waits in idle samples.
    "kevent",
    "__workq_kernreturn",
)


def parse_tab_counts(text):
    counts = []
    for part in text.split(","):
        piece = part.strip()
        if not piece:
            continue
        try:
            count = int(piece)
        except ValueError as error:
            raise SystemExit(f"tab count is not an integer: {piece}") from error
        if count not in ALLOWED_TAB_COUNTS:
            allowed = ", ".join(str(item) for item in ALLOWED_TAB_COUNTS)
            raise SystemExit(f"tab count must be one of {allowed}: {count}")
        counts.append(count)
    if not counts:
        raise SystemExit("at least one tab count is required")
    return counts


def main_thread_sample(pid):
    """Two-second sample of the Swift process main thread while the page is idle."""
    handle = tempfile.NamedTemporaryFile(
        prefix="shaar-main-thread-", suffix=".txt", delete=False)
    path = handle.name
    handle.close()
    try:
        completed = subprocess.run(
            ["sample", str(pid), "2", "-mayDie", "-file", path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
            timeout=12,
            check=False,
        )
        if completed.returncode != 0 or not os.path.isfile(path):
            return {
                "mainThreadSample": "unavailable",
                "mainThreadSampleError": (completed.stderr or "")[-500:],
            }
        return parse_main_thread_sample(Path(path).read_text(errors="replace"))
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"mainThreadSample": "unavailable", "mainThreadSampleError": str(error)}
    finally:
        try:
            os.remove(path)
        except OSError:
            pass


def next_sampled_thread(line, indent):
    if len(line) - len(line.lstrip(" ")) != indent:
        return False
    body = line.strip()
    return body[:1].isdigit() and "Thread_" in body


def sample_section_ended(line):
    # These summaries follow every thread and repeat frames from the whole process.
    text = line.strip()
    return (
        text.startswith("Total number in stack")
        or text.startswith("Sort by top of stack")
        or text.startswith("Binary Images:")
    )


def stack_frame(line):
    # sample keeps every line at the same left margin. Depth is the column of the count.
    match = re.search(r"(\d+)\s+(\S.*)$", line)
    if match is None:
        return None
    return match.start(1), int(match.group(1)), match.group(2)


def frame_is_wait(frame):
    return any(trap in frame for trap in WAIT_TRAPS)


def parse_main_thread_sample(text):
    lines = text.splitlines()
    start = None
    for index, line in enumerate(lines):
        if "com.apple.main-thread" in line:
            start = index
            break
    if start is None:
        return {
            "mainThreadSample": "unavailable",
            "mainThreadSampleError": "main thread missing",
        }
    header = lines[start].strip()
    header_count = header.split(maxsplit=1)[0]
    try:
        total = int(header_count.lstrip("+!|:"))
    except ValueError:
        return {
            "mainThreadSample": "unavailable",
            "mainThreadSampleError": "main thread count missing",
        }
    indent = len(lines[start]) - len(lines[start].lstrip(" "))
    frames = []
    for line in lines[start + 1:]:
        if not line.strip():
            continue
        if sample_section_ended(line) or next_sampled_thread(line, indent):
            break
        parsed = stack_frame(line)
        if parsed is None:
            continue
        column, count, frame = parsed
        frames.append({
            "column": column,
            "count": count,
            "frame": frame,
            "parent": None,
            "waits": frame_is_wait(frame),
        })
    for index, frame in enumerate(frames):
        for earlier in range(index - 1, -1, -1):
            if frames[earlier]["column"] < frame["column"]:
                frame["parent"] = earlier
                break
    for frame in reversed(frames):
        parent = frame["parent"]
        if frame["waits"] and parent is not None:
            frames[parent]["waits"] = True
    wait_samples = 0
    for index, frame in enumerate(frames):
        if not frame_is_wait(frame["frame"]):
            continue
        nested = False
        for later in frames[index + 1:]:
            if later["column"] <= frame["column"]:
                break
            if frame_is_wait(later["frame"]):
                nested = True
                break
        if not nested:
            wait_samples += frame["count"]
    top_busy = 0
    top_frame = ""
    for frame in frames:
        if frame["waits"] or "start" in frame["frame"] or "dyld" in frame["frame"]:
            continue
        if frame["count"] > top_busy:
            top_busy = frame["count"]
            top_frame = frame["frame"][:180]
    busy = max(0, total - wait_samples)
    return {
        "mainThreadSample": "ok",
        "mainThreadSamples": total,
        "mainThreadWaitSamples": wait_samples,
        "mainThreadBusyPercent": round(100 * busy / total, 1) if total else None,
        "mainThreadTopFrame": top_frame,
        # A hang here means the main thread stayed out of the run-loop wait for
        # at least half of a 2 second idle sample (about one second of work).
        "mainThreadHang": bool(total) and busy * 2 >= total,
    }


def measure_case(executable, port, tab_count, sample_seconds, eager):
    with tempfile.TemporaryDirectory(prefix="arcusis-engine-probe-") as temporary:
        root = Path(temporary)
        (root / ".arcusis-probe").write_text("arcusis-engine-probe-v1\n")
        report = root / "initial.json"
        command = [
            str(executable), "--probe-data-dir", str(root),
            "--probe-url", f"http://127.0.0.1:{port}/page-1",
            "--probe-phase", "initial", "--probe-output", str(report),
            "--probe-measure-tabs", str(tab_count), "--probe-measure-seconds",
            str(max(60, sample_seconds + 30)),
        ]
        if eager:
            command.append("--probe-measure-eager")
        started = time.monotonic()
        stderr_path = root / "probe-stderr.txt"
        stderr_file = stderr_path.open("w")
        process = subprocess.Popen(
            command, stdout=subprocess.DEVNULL, stderr=stderr_file,
            start_new_session=True,
        )
        deadline = started + (240 if tab_count >= 50 else 150)
        try:
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    stderr_file.flush()
                    error = stderr_path.read_text(errors="replace")[-3000:]
                    raise RuntimeError(f"probe exited {process.returncode}: {error}")
                if report.exists():
                    break
                time.sleep(0.05)
            else:
                raise TimeoutError(f"{tab_count}-tab probe did not become ready")
            ready = json.loads(report.read_text())
            if ready.get("tabs") != tab_count:
                raise RuntimeError(f"unexpected readiness report: {ready}")
            expected_live = tab_count if eager else 1
            if (ready.get("mode") != ("eager" if eager else "lazy")
                    or ready.get("liveTabs") != expected_live
                    or ready.get("placeholders") != tab_count - expected_live):
                raise RuntimeError(f"unexpected materialization report: {ready}")
            cold_seconds = time.monotonic() - started
            rss_samples, app_rss_samples, cpu_samples, process_samples = [], [], [], []
            sample_end = time.monotonic() + sample_seconds
            previous_time = time.monotonic()
            previous_cpu = sum(
                row[2] for _pid, row in process_tree(process.pid)
            )
            while time.monotonic() < sample_end:
                if process.poll() is not None:
                    raise RuntimeError(f"probe exited during sampling: {process.returncode}")
                tree = process_tree(process.pid)
                now = time.monotonic()
                rss_samples.append(sum(row[1] for _pid, row in tree) / 1024)
                app_row = next((row for pid, row in tree if pid == process.pid), None)
                if app_row is not None:
                    app_rss_samples.append(app_row[1] / 1024)
                process_samples.append(len(tree))
                cpu = sum(row[2] for _pid, row in tree)
                elapsed = max(0.001, now - previous_time)
                cpu_samples.append(max(0.0, cpu - previous_cpu) / elapsed * 100)
                previous_time, previous_cpu = now, cpu
                time.sleep(1)
            # Sample after the CPU window so the sampler's own cost stays out of idle CPU.
            thread = main_thread_sample(process.pid) if process.poll() is None else {
                "mainThreadSample": "unavailable",
                "mainThreadSampleError": "probe exited before the main-thread sample",
            }
            result = {
                "tabs": tab_count,
                "mode": "eager" if eager else "lazy",
                "coldLaunchToReadySeconds": round(cold_seconds, 3),
                "readiness": "all-pages" if eager else "selected-page",
                "processTreeRSSMiBMean": round(sum(rss_samples) / len(rss_samples), 1),
                "processTreeRSSMiBMin": round(min(rss_samples), 1),
                "processTreeRSSMiBMax": round(max(rss_samples), 1),
                "appRSSMiBMean": round(sum(app_rss_samples) / len(app_rss_samples), 1)
                if app_rss_samples else None,
                "processTreeCountMean": round(sum(process_samples) / len(process_samples), 1),
                "idleCPUPercentMean": round(sum(cpu_samples) / len(cpu_samples), 2),
                "samples": len(rss_samples),
            }
            result.update(thread)
            return result
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
            stderr_file.close()


def annotate_marginal_rss(cases):
    """RSS added by each saved tab beyond the 1-tab case in this same run."""
    baseline = next((case for case in cases if case["tabs"] == 1), None)
    if baseline is None:
        return
    base = baseline["processTreeRSSMiBMean"]
    for case in cases:
        extra = case["tabs"] - 1
        if extra <= 0:
            case["marginalRSSMiBPerExtraTab"] = None
            continue
        case["marginalRSSMiBPerExtraTab"] = round(
            (case["processTreeRSSMiBMean"] - base) / extra, 2)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, default=Path("build/Shaar Verification.app"))
    parser.add_argument(
        "--output", type=Path, default=Path("build/performance-baseline.json")
    )
    parser.add_argument("--sample-seconds", type=int, default=15)
    parser.add_argument(
        "--tab-counts", default="1,10,30",
        help="Comma-separated saved-tab counts. Allowed: 1, 10, 30, 50, 100.",
    )
    parser.add_argument("--eager", action="store_true", help="measure the former eager probe mode")
    args = parser.parse_args()
    tab_counts = parse_tab_counts(args.tab_counts)
    executable = args.app / "Contents/MacOS/ShaarVerification"
    if not executable.is_file():
        raise SystemExit(f"verification executable not found: {executable}")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        cases = [
            measure_case(
                executable, server.server_port, count, args.sample_seconds, args.eager)
            for count in tab_counts
        ]
    finally:
        server.shutdown()
        server.server_close()
    annotate_marginal_rss(cases)
    result = {
        "schema": 3,
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
