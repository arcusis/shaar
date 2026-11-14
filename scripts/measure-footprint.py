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
    "mach_msg_overwrite_trap",
    "semaphore_wait_trap",
    "semaphore_wait_signal_trap",
    "semaphore_timedwait_trap",
    "semaphore_timedwait_signal_trap",
    "__semwait_signal",
    "__psynch_cvwait",
    "__psynch_mutexwait",
    # __psynch_rw_rdlock, __psynch_rw_wrlock, and __psynch_rw_unlock.
    "__psynch_rw_",
    "__ulock_wait",
    "swtch_pri",
    # kevent64 and __workq_kernreturn are waits in idle samples.
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


def positive_seconds(text):
    try:
        seconds = int(text)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be an integer number of seconds") from error
    if seconds <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return seconds


def main_thread_sample(pid, copy_path=None):
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
        text = Path(path).read_text(errors="replace")
        if copy_path is not None:
            destination = Path(copy_path)
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(text)
        return parse_main_thread_sample(text)
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


def frame_symbol(frame):
    parts = frame.split(maxsplit=1)
    return parts[0] if parts else ""


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
        })
    leaf_waits = []
    for index, frame in enumerate(frames):
        leaf = 0
        if frame_is_wait(frame["frame"]):
            nested = False
            for later in frames[index + 1:]:
                if later["column"] <= frame["column"]:
                    break
                if frame_is_wait(later["frame"]):
                    nested = True
                    break
            if not nested:
                leaf = frame["count"]
        leaf_waits.append(leaf)
    wait_samples = sum(leaf_waits)
    top_busy = 0
    top_column = -1
    top_frame = ""
    for index, frame in enumerate(frames):
        symbol = frame_symbol(frame["frame"])
        # "start" is the dyld entry symbol. A substring match also drops startup frames.
        if symbol == "start" or "dyld" in frame["frame"]:
            continue
        waited = leaf_waits[index]
        for later_index in range(index + 1, len(frames)):
            if frames[later_index]["column"] <= frame["column"]:
                break
            waited += leaf_waits[later_index]
        busy_count = frame["count"] - waited
        deeper = busy_count == top_busy and frame["column"] > top_column
        if busy_count > top_busy or (busy_count > 0 and deeper):
            top_busy = busy_count
            top_column = frame["column"]
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


def measure_case(
        executable, port, tab_count, sample_seconds, eager, inspector,
        sleeping=False, sample_copy=None):
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
        if sleeping:
            command.append("--probe-measure-sleeping")
        if inspector:
            command.append("--probe-measure-inspector")
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
            expected_mode = "sleeping" if sleeping else ("eager" if eager else "lazy")
            if (ready.get("mode") != expected_mode
                    or ready.get("liveTabs") != expected_live
                    or ready.get("placeholders") != tab_count - expected_live):
                raise RuntimeError(f"unexpected materialization report: {ready}")
            expected_sleeping = tab_count - 1 if sleeping else 0
            if ready.get("sleepingTabs") != expected_sleeping:
                raise RuntimeError(f"unexpected sleeping-tab report: {ready}")
            if inspector and (
                ready.get("inspector") is not True or ready.get("inspectorLocked") is not True
            ):
                raise RuntimeError(f"inspector was not locked for measurement: {ready}")
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
            thread = main_thread_sample(process.pid, sample_copy) if process.poll() is None else {
                "mainThreadSample": "unavailable",
                "mainThreadSampleError": "probe exited before the main-thread sample",
            }
            result = {
                "tabs": tab_count,
                "mode": expected_mode,
                "sleepingTabs": expected_sleeping,
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
            if inspector:
                sidecar = root / "inspector-poll.json"
                deadline = time.monotonic() + 2
                while not sidecar.is_file() and time.monotonic() < deadline:
                    time.sleep(0.05)
                if not sidecar.is_file():
                    raise RuntimeError("inspector poll sidecar missing")
                samples = json.loads(sidecar.read_text()).get("samples") or []
                if not samples:
                    raise RuntimeError("inspector poll sidecar was empty")
                last = samples[-1]
                calls = last["calls"]
                elapsed = last["elapsedSeconds"]
                if not isinstance(calls, int) or isinstance(calls, bool) or calls < 0:
                    raise RuntimeError(f"inspector poll counter was negative or missing: {calls}")
                if not isinstance(elapsed, (int, float)) or isinstance(elapsed, bool) or elapsed < 0:
                    raise RuntimeError(f"inspector poll elapsed time was invalid: {elapsed}")
                result["inspectorPollCalls"] = calls
                result["inspectorPollElapsedSeconds"] = elapsed
                result["inspectorPollCallsPerSecond"] = (
                    round(calls / elapsed, 2) if elapsed else None
                )
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


def compare_sleeping_rss(cases):
    """Report the measured RSS reduction for sleeping tabs at matching tab counts."""
    by_case = {(case["tabs"], case["mode"]): case for case in cases}
    comparisons = []
    counts = sorted({case["tabs"] for case in cases})
    for count in counts:
        awake = by_case.get((count, "eager"))
        sleeping = by_case.get((count, "sleeping"))
        if awake is None or sleeping is None:
            continue
        awake_rss = awake["processTreeRSSMiBMean"]
        sleeping_rss = sleeping["processTreeRSSMiBMean"]
        saved = awake_rss - sleeping_rss
        comparisons.append({
            "tabs": count,
            "awakeProcessTreeRSSMiBMean": awake_rss,
            "sleepingProcessTreeRSSMiBMean": sleeping_rss,
            "processTreeRSSMiBSaved": round(saved, 1),
            "processTreeRSSReductionPercent": round(100 * saved / awake_rss, 1)
            if awake_rss else None,
        })
    return comparisons


def write_report(path: Path, result: dict) -> None:
    if path.is_symlink():
        raise ValueError(f"performance report path must not be a symlink: {path}")
    if path.exists() and not path.is_file():
        raise ValueError(f"performance report path is not a regular file: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(result, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, default=Path("build/Shaar Verification.app"))
    parser.add_argument(
        "--output", type=Path, default=Path("build/performance-baseline.json")
    )
    parser.add_argument("--sample-seconds", type=positive_seconds, default=15)
    parser.add_argument(
        "--tab-counts", default=None,
        help="Comma-separated saved-tab counts. Allowed: 1, 10, 30, 50, 100.",
    )
    parser.add_argument("--eager", action="store_true", help="measure the former eager probe mode")
    parser.add_argument(
        "--sleeping", action="store_true",
        help="eagerly load fixture tabs, then sleep every background tab before sampling RSS",
    )
    parser.add_argument(
        "--compare-sleeping", action="store_true",
        help="measure eager and sleeping tabs for each tab count and report RSS saved",
    )
    parser.add_argument(
        "--inspector", action="store_true",
        help="open Inspector, lock the page, and record how often it reads",
    )
    parser.add_argument(
        "--sample-out", type=Path, default=None,
        help="Directory where each case's raw main-thread sample is copied before it is deleted.",
    )
    args = parser.parse_args()
    if args.sleeping and (args.compare_sleeping or args.eager or args.inspector):
        parser.error("--sleeping cannot be combined with --eager, --inspector, or --compare-sleeping")
    if args.compare_sleeping and (args.eager or args.inspector):
        parser.error("--compare-sleeping cannot be combined with --eager or --inspector")
    default_counts = "50,100" if args.compare_sleeping else "1,10,30"
    tab_counts = parse_tab_counts(args.tab_counts or default_counts)
    executable = args.app / "Contents/MacOS/ShaarVerification"
    if not executable.is_file():
        raise SystemExit(f"verification executable not found: {executable}")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        counts = (1,) if args.inspector else tab_counts
        cases = []
        for count in counts:
            copy = None
            if args.sample_out is not None:
                mode = "sleeping" if args.sleeping else ("eager" if args.eager else "lazy")
                copy = args.sample_out / f"{count}-{mode}.txt"
            if args.compare_sleeping:
                for mode, sleeping in (("eager", False), ("sleeping", True)):
                    cases.append(measure_case(
                        executable, server.server_port, count, args.sample_seconds,
                        True, False, sleeping,
                        args.sample_out / f"{count}-{mode}.txt" if args.sample_out else None,
                    ))
            else:
                cases.append(measure_case(
                    executable, server.server_port, count, args.sample_seconds,
                    args.eager or args.sleeping, args.inspector, args.sleeping, copy,
                ))
    finally:
        server.shutdown()
        server.server_close()
    annotate_marginal_rss(cases)
    sleeping_comparison = compare_sleeping_rss(cases) if args.compare_sleeping else None
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
    if sleeping_comparison is not None:
        result["sleepingComparison"] = sleeping_comparison
    write_report(args.output, result)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
