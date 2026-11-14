#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Exercise everyday browsing in a hidden Shaar Verification.app."""

from __future__ import annotations

import argparse
from datetime import datetime, timedelta, timezone
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parents[1]
CRASH_DIRECTORIES = (
    Path.home() / "Library/Logs/DiagnosticReports",
    Path.home() / "Library/Logs/DiagnosticReports/Retired",
)
CRASH_PREFIXES = ("Shaar", "ArcusisBrowser", "Chromium")
LATE_CRASH_SECONDS = 8
GIBIBYTE = 1024 ** 3
OVERLOAD_CEILING = 8 * GIBIBYTE
OVERLOAD_HEADROOM = 4 * GIBIBYTE
DEFAULT_SCENARIOS = (
    "overload-50",
    "overload-100",
    "overload-200",
    "churn",
    "windows",
    "splits",
    "heavy",
    "dialogs",
    "downloads",
    "renderer",
    "restore-seed",
    "restore-check",
)
TIMEOUTS = {
    "overload-50": 240,
    "overload-100": 300,
    "overload-200": 420,
    "churn": 240,
    "windows": 240,
    "splits": 240,
    "heavy": 240,
    "dialogs": 240,
    "downloads": 240,
    "renderer": 240,
    "restore-seed": 240,
    "restore-check": 240,
}


class UnknownScenario(ValueError):
    """Raised when a requested scenario name is not part of this probe."""


def parse_scenarios(text: str | None) -> list[str]:
    if not text:
        return list(DEFAULT_SCENARIOS)
    names = [part.strip() for part in text.split(",") if part.strip()]
    unknown = [name for name in names if name not in DEFAULT_SCENARIOS]
    if unknown:
        raise UnknownScenario(", ".join(unknown))
    return names


def earlier_overload(count: int, samples: dict[int, int]) -> tuple[int, int] | None:
    smaller = [item for item in samples if item < count]
    if not smaller:
        return None
    chosen = max(smaller)
    return chosen, samples[chosen]


def allow_overload(
    count: int, prior_count: int | None, prior_peak_bytes: int | None, available_bytes: int | None
) -> tuple[bool, str]:
    """Decide whether a larger tab burst is safe on this host."""
    if count <= 50:
        return True, ""
    if prior_count is None or prior_peak_bytes is None or prior_count <= 0:
        return False, "skipped because the smaller overload run has no memory sample"
    if available_bytes is None:
        return False, "skipped because available memory could not be read"
    projected = prior_peak_bytes * count // prior_count
    if projected > OVERLOAD_CEILING:
        return False, f"skipped because projected RSS {projected} exceeds 8 GiB"
    if projected + OVERLOAD_HEADROOM > available_bytes:
        return False, "skipped because projected RSS plus 4 GiB exceeds available memory"
    return True, ""


def scenario_result(report: dict, exit_code: int | None, timed_out: bool, crashes: list[str]) -> str:
    if timed_out:
        return "hang"
    if crashes:
        return "fail"
    if "passed" not in report:
        return "fail"
    rows = report.get("rows")
    if not isinstance(rows, list) or not rows:
        return "fail"
    if any(
        not isinstance(row, dict)
        or not isinstance(row.get("status"), str)
        or row.get("status") not in {"pass", "blocked"}
        for row in rows
    ):
        return "fail"
    if report.get("passed") is not True or exit_code not in (0, None):
        return "fail"
    if all(row.get("status") == "blocked" for row in rows):
        return "blocked"
    return "pass"


def crash_counts_against_suite(
    scenario: str, report: dict, crash_text: str, finished: datetime | None = None,
) -> bool:
    """A deliberate renderer SIGKILL is evidence for the recovery row, not a second defect."""
    if scenario != "renderer" or finished is None:
        return True
    rows = report.get("rows")
    recovered = isinstance(rows, list) and any(
        isinstance(row, dict)
        and row.get("name") == "renderer-recover"
        and row.get("status") == "pass"
        for row in rows
    )
    return not (recovered and deliberate_renderer_kill(report, crash_text, finished))


def deliberate_renderer_kill(report: dict, crash_text: str, finished: datetime) -> bool:
    signaled: set[int] = set()
    signaled_at = None
    rows = report.get("rows")
    if not isinstance(rows, list):
        return False
    for row in rows:
        if not isinstance(row, dict):
            continue
        pids = row.get("signaledPIDs")
        for pid in pids if isinstance(pids, list) else []:
            if isinstance(pid, int):
                signaled.add(pid)
        parsed = parse_signaled_at(row.get("signaledAt"))
        if parsed is not None:
            signaled_at = parsed
    if not signaled or signaled_at is None:
        return False
    identity = crash_identity(crash_text)
    if identity is None:
        return False
    pid, when = identity
    if pid not in signaled:
        return False
    return signaled_at - timedelta(seconds=2) <= when <= finished


def parse_signaled_at(value: object) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed


def crash_identity(text: str) -> tuple[int, datetime] | None:
    pid_match = re.search(r'"pid"\s*:\s*(\d+)', text)
    time_match = re.search(r'"captureTime"\s*:\s*"([^"]+)"', text)
    if pid_match is None or time_match is None:
        return None
    when = parse_crash_time(time_match.group(1))
    if when is None:
        return None
    return int(pid_match.group(1)), when


def parse_crash_time(value: str) -> datetime | None:
    for fmt in ("%Y-%m-%d %H:%M:%S.%f %z", "%Y-%m-%d %H:%M:%S %z"):
        try:
            return datetime.strptime(value, fmt)
        except ValueError:
            continue
    return None


def suite_passed(scenarios: list[dict]) -> bool:
    for item in scenarios:
        result = item.get("result")
        if result == "pass":
            continue
        scenario = str(item.get("scenario", ""))
        if result == "blocked" and not scenario.startswith("overload-"):
            continue
        return False
    return True


def format_mib(value: int | None) -> str:
    if value is None:
        return ""
    return f"{value / (1024 * 1024):.0f} MiB"


def markdown_table(scenarios: list[dict]) -> str:
    lines = [
        "| Scenario | Result | Seconds | Peak RSS | Crashes | Notes |",
        "| --- | --- | ---: | ---: | --- | --- |",
    ]
    for item in scenarios:
        crashes = ", ".join(item.get("crashes") or []) or "none"
        notes = " ".join(str(item.get("notes") or "").split()).replace("|", "/")
        if len(notes) > 180:
            notes = notes[:179] + "…"
        seconds = item.get("seconds")
        second_text = "" if seconds is None else f"{float(seconds):.0f}"
        lines.append(
            "| {scenario} | {result} | {seconds} | {rss} | {crashes} | {notes} |".format(
                scenario=item.get("scenario", ""),
                result=item.get("result", ""),
                seconds=second_text,
                rss=format_mib(item.get("peakRSSBytes")),
                crashes=crashes,
                notes=notes,
            )
        )
    return "\n".join(lines) + "\n"


def available_bytes() -> int | None:
    try:
        page = int(
            subprocess.check_output(
                ["sysctl", "-n", "hw.pagesize"], text=True, timeout=5).strip())
        text = subprocess.check_output(["vm_stat"], text=True, timeout=5)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    pages: dict[str, int] = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        key, raw = line.split(":", 1)
        number = raw.strip().rstrip(".")
        if number.isdigit():
            pages[key.strip()] = int(number)
    if not pages:
        return None
    reclaimable = (
        pages.get("Pages free", 0)
        + pages.get("Pages inactive", 0)
        + pages.get("Pages speculative", 0)
    )
    return reclaimable * page


def crash_paths() -> list[Path]:
    found = []
    for directory in CRASH_DIRECTORIES:
        if not directory.is_dir():
            continue
        for path in directory.iterdir():
            if path.suffix in {".ips", ".crash"} and path.name.startswith(CRASH_PREFIXES):
                found.append(path)
    return found


def crash_names() -> set[str]:
    return {path.name for path in crash_paths()}


def collect_new_crashes(before: set[str]) -> list[tuple[str, str]]:
    """Keep polling for the whole late-crash window. Reports often land seconds apart."""
    deadline = time.monotonic() + LATE_CRASH_SECONDS
    found = read_new_crashes(before)
    while time.monotonic() < deadline:
        remaining = deadline - time.monotonic()
        time.sleep(min(1, max(0, remaining)))
        found = read_new_crashes(before)
    return found


def read_new_crashes(before: set[str]) -> list[tuple[str, str]]:
    reports = []
    for path in crash_paths():
        if path.name in before:
            continue
        try:
            text = path.read_text(errors="replace")[:8000]
        except OSError:
            text = ""
        reports.append((path.name, text))
    return reports


def process_tree_rss_bytes(root_pid: int) -> int:
    try:
        output = subprocess.check_output(
            ["ps", "-axo", "pid=,ppid=,rss="], text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return 0
    rows: dict[int, tuple[int, int]] = {}
    for line in output.splitlines():
        parts = line.split()
        if len(parts) != 3 or not all(part.isdigit() for part in parts):
            continue
        pid, ppid, rss = (int(part) for part in parts)
        rows[pid] = (ppid, rss)
    members = {root_pid}
    changed = True
    while changed:
        changed = False
        for pid, (ppid, _rss) in rows.items():
            if ppid in members and pid not in members:
                members.add(pid)
                changed = True
    kilobytes = sum(rows[pid][1] for pid in members if pid in rows)
    return kilobytes * 1024


def prepare_root() -> Path:
    root = Path(tempfile.mkdtemp(prefix="arcusis-engine-probe-"))
    root.chmod(0o700)
    marker = root / ".arcusis-probe"
    marker.write_text("arcusis-engine-probe-v1\n")
    marker.chmod(0o600)
    (root / "home").mkdir()
    return root


def probe_environment(root: Path) -> dict[str, str]:
    home = str(root / "home")
    environment = dict(os.environ)
    environment["HOME"] = home
    environment["CFFIXED_USER_HOME"] = home
    environment["SHAAR_ENGINE_TESTING"] = "1"
    environment["SHAAR_MOCK_KEYCHAIN"] = "1"
    return environment


def stop_process(process: subprocess.Popen) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def read_report(path: Path) -> dict:
    if not path.is_file():
        return {}
    try:
        value = json.loads(path.read_text())
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def row_notes(report: dict, extra: str) -> str:
    parts = [extra] if extra else []
    rows = report.get("rows")
    if not isinstance(rows, list):
        return " ".join(parts + ["Malformed scenario rows."])
    for row in rows:
        if not isinstance(row, dict):
            parts.append("Malformed scenario row.")
            continue
        status = row.get("status")
        if not isinstance(status, str) or status not in {"pass", "fail", "blocked"}:
            parts.append("Malformed scenario row status.")
            continue
        if status in {"fail", "blocked"}:
            parts.append(f"{row.get('name')}: {row.get('detail') or ''}".strip())
    return " ".join(parts)


def blocked_scenario(name: str, notes: str) -> dict:
    return {
        "scenario": name,
        "result": "blocked",
        "seconds": 0,
        "peakRSSBytes": None,
        "crashes": [],
        "unexpectedCrashes": [],
        "exitCode": None,
        "rows": [],
        "notes": notes,
    }


def favicon_png() -> bytes:
    spec = importlib.util.spec_from_file_location(
        "shaar_favicon_png", ROOT / "scripts/test-shaar-favicon.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.png()


def make_clip(directory: Path) -> bytes:
    ffmpeg = shutil.which("ffmpeg")
    target = directory / "clip.mp4"
    if not ffmpeg:
        return b""
    try:
        subprocess.run(
            [
                ffmpeg, "-y", "-loglevel", "error",
                "-f", "lavfi", "-i", "color=c=black:s=160x120:d=1",
                "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono",
                "-shortest", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
                str(target),
            ],
            check=False, capture_output=True, timeout=30,
        )
    except subprocess.TimeoutExpired:
        return b""
    if target.is_file() and target.stat().st_size > 0:
        return target.read_bytes()
    return b""


def page(title: str, body: str) -> bytes:
    return f"<!doctype html><meta charset=utf-8><title>{title}</title>{body}".encode()


class Fixture(BaseHTTPRequestHandler):
    icon = b""
    clip = b""
    heavy = b""
    slow_reload_lock = threading.Lock()
    slow_reload_requests: dict[str, int] = {}

    @classmethod
    def next_slow_reload_request(cls, path: str) -> int:
        with cls.slow_reload_lock:
            request = cls.slow_reload_requests.get(path, 0) + 1
            cls.slow_reload_requests[path] = request
            return request

    def do_GET(self) -> None:
        try:
            self.respond()
        except (BrokenPipeError, ConnectionResetError):
            return

    def respond(self) -> None:
        path = urlsplit(self.path).path
        port = self.server.server_port
        destination = f"http://127.0.0.1:{port}/dest"
        if path == "/slow":
            time.sleep(1.5)
            self.send_bytes(page("slow", "<p>slow</p>"), "text/html; charset=utf-8")
            return
        if path.startswith("/slow-reload/"):
            request = self.next_slow_reload_request(path)
            time.sleep(1.5)
            body = f'<script>document.documentElement.dataset.reloadRequest="{request}"</script>'
            self.send_bytes(page("slow reload", body), "text/html; charset=utf-8")
            return
        if path == "/heavy":
            self.send_bytes(self.heavy, "text/html; charset=utf-8")
            return
        if path == "/icon.png":
            self.send_bytes(self.icon, "image/png")
            return
        if path == "/clip.mp4":
            self.send_bytes(self.clip, "video/mp4")
            return
        if path == "/file-a.txt":
            self.send_bytes(b"profile-a\n", "text/plain", "file-a.txt")
            return
        if path == "/file-b.txt":
            self.send_bytes(b"profile-b\n", "text/plain", "file-b.txt")
            return
        if path == "/missing":
            self.send_bytes(b"404 missing", "text/plain", status=404)
            return
        if path == "/error":
            self.send_bytes(b"500 error", "text/plain", status=500)
            return
        body = self.document(path, destination)
        if body is None:
            self.send_bytes(b"missing", "text/plain", status=404)
            return
        self.send_bytes(body, "text/html; charset=utf-8")

    def document(self, path: str, destination: str) -> bytes | None:
        if path == "/light" or path.startswith("/restore/"):
            return page(path.strip("/"), f"<p>{path}</p>")
        if path.startswith("/nav/"):
            return page(path, f"<p>{path}</p>")
        if path == "/scroll":
            return page("scroll", """
<style>#feed{height:220px;overflow:auto}#feed div{height:40px}</style>
<div id="feed"></div>
<script>
const feed=document.getElementById('feed');
function add(n){for(let i=0;i<n;i++){const row=document.createElement('div');row.textContent=String(feed.children.length);feed.appendChild(row);}}
add(100);
window.__scrollEvents=0;
feed.addEventListener('scroll',()=>{window.__scrollEvents++;if(feed.children.length<200)add(100);});
</script>""")
        if path == "/webgl":
            return page("webgl", """
<canvas id="c" width="32" height="32"></canvas>
<script>
const gl=document.getElementById('c').getContext('webgl')||document.getElementById('c').getContext('experimental-webgl');
document.documentElement.dataset.webgl=gl?'1':'0';
</script>""")
        if path == "/video":
            if not self.clip:
                return page("video", "<script>document.documentElement.dataset.clip='0'</script>")
            return page("video", """
<script>document.documentElement.dataset.clip='1'</script>
<video id="clip" src="/clip.mp4" playsinline></video>
<button id="popup" onclick="const video=document.getElementById('clip');document.documentElement.dataset.playClick=String(event.isTrusted);video.play().then(()=>document.documentElement.dataset.playResult='resolved',error=>document.documentElement.dataset.playResult=error.name)">Play</button>
<script>for(const name of ['pointerdown','mousedown','mouseup','click'])document.addEventListener(name,event=>document.documentElement.dataset['probe'+name]=[event.target.id||event.target.tagName,event.isTrusted,event.clientX,event.clientY].join(','),true)</script>""")
        if path == "/popup":
            return page("popup", f"""
<a id="blank" target="_blank" href="{destination}">New tab</a>
<button id="popup" onclick="window.open('{destination}','_blank')">Open</button>""")
        if path == "/unload":
            return page("unload", """
<button id="popup" onclick="window.onbeforeunload=function(event){event.preventDefault();event.returnValue='';document.documentElement.dataset.prompted='1';};document.documentElement.dataset.armed='1'">Arm</button>""")
        if path == "/favicon":
            return page("favicon", '<link rel="icon" href="/icon.png"><p>favicon</p>')
        if path == "/dest":
            return page("dest", "<p>destination</p>")
        return None

    def send_bytes(
        self, body: bytes, content_type: str, download_name: str | None = None, status: int = 200
    ) -> None:
        start = 0
        end = max(len(body) - 1, 0)
        status_code = status
        chunk = body
        range_header = self.headers.get("Range")
        if status == 200 and body and range_header and range_header.startswith("bytes="):
            spec = range_header.split("=", 1)[1].split(",", 1)[0].strip()
            left, _, right = spec.partition("-")
            if left.isdigit():
                start = int(left)
            if right.isdigit():
                end = min(int(right), len(body) - 1)
            if 0 <= start <= end < len(body):
                status_code = 206
                chunk = body[start:end + 1]
        self.send_response(status_code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(chunk)))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Cache-Control", "no-store")
        if status_code == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(body)}")
        if download_name:
            self.send_header("Content-Disposition", f'attachment; filename="{download_name}"')
        self.end_headers()
        self.wfile.write(chunk)

    def log_message(self, format, *args) -> None:
        return


def launch_scenario(executable: Path, root: Path, page_url: str, scenario: str) -> dict:
    report_path = root / "report.json"
    if report_path.exists():
        report_path.unlink()
    stderr_path = root / f"{scenario}.stderr"
    before = crash_names()
    started = time.monotonic()
    environment = probe_environment(root)
    command = [str(executable), "--browsing-qa", str(report_path), page_url, scenario]
    timed_out = False
    with stderr_path.open("w") as stderr:
        process = subprocess.Popen(
            command, env=environment, stdout=subprocess.DEVNULL, stderr=stderr,
            start_new_session=True,
        )
        peak = 0
        deadline = time.monotonic() + TIMEOUTS[scenario]
        while True:
            peak = max(peak, process_tree_rss_bytes(process.pid))
            if process.poll() is not None:
                break
            if time.monotonic() >= deadline:
                timed_out = True
                stop_process(process)
                break
            time.sleep(0.5)
    report = read_report(report_path)
    crash_reports = collect_new_crashes(before)
    finished_at = datetime.now(timezone.utc)
    names = [name for name, _text in crash_reports]
    unexpected = [
        name for name, text in crash_reports
        if crash_counts_against_suite(scenario, report, text, finished_at)
    ]
    extra = ""
    if timed_out:
        extra = "The verification app was still running when the scenario budget ended."
    elif names and not unexpected:
        extra = "Crash report is the deliberate renderer SIGKILL."
    if not report.get("rows") and stderr_path.is_file():
        tail = stderr_path.read_text(errors="replace")[-400:].strip()
        if tail:
            extra = (extra + " " + tail).strip()
    result = scenario_result(report, process.returncode, timed_out, unexpected)
    return {
        "scenario": scenario,
        "result": result,
        "seconds": round(time.monotonic() - started, 1),
        "peakRSSBytes": peak,
        "crashes": names,
        "unexpectedCrashes": unexpected,
        "exitCode": process.returncode,
        "rows": report.get("rows") or [],
        "allWindowsHidden": report.get("allWindowsHidden"),
        "notes": row_notes(report, extra),
    }


def run_suite(
    executable: Path, scenarios: list[str], page_url: str, on_result=None
) -> list[dict]:
    results = []
    samples: dict[int, int] = {}
    restore_root: Path | None = None
    skipped_larger = False

    def record(item):
        results.append(item)
        if on_result is not None:
            on_result(results)
        print(
            f"finished {item['scenario']}: {item['result']} in {item['seconds']}s "
            f"rss={format_mib(item.get('peakRSSBytes'))}",
            flush=True,
        )

    for scenario in scenarios:
        if scenario.startswith("overload-"):
            count = int(scenario.split("-", 1)[1])
            if skipped_larger:
                reason = "skipped because a smaller overload was already too large"
                print(f"blocked {scenario}: {reason}", flush=True)
                record(blocked_scenario(scenario, reason))
                continue
            prior = earlier_overload(count, samples)
            prior_count, prior_peak = prior if prior else (None, None)
            allowed, reason = allow_overload(count, prior_count, prior_peak, available_bytes())
            if not allowed:
                skipped_larger = True
                print(f"blocked {scenario}: {reason}", flush=True)
                record(blocked_scenario(scenario, reason))
                continue
        root = None
        delete_after = False
        try:
            if scenario == "restore-check" and restore_root is not None:
                root = restore_root
            else:
                root = prepare_root()
                if scenario == "restore-seed":
                    restore_root = root
            delete_after = scenario != "restore-seed"
            print(f"running {scenario}", flush=True)
            item = launch_scenario(executable, root, page_url, scenario)
        except Exception as error:
            item = blocked_scenario(scenario, "")
            item["result"] = "fail"
            item["notes"] = str(error)
        finally:
            if delete_after and root is not None:
                shutil.rmtree(root, ignore_errors=True)
        record(item)
        if scenario.startswith("overload-") and item.get("peakRSSBytes"):
            samples[int(scenario.split("-", 1)[1])] = item["peakRSSBytes"]
    if restore_root is not None and "restore-check" not in scenarios:
        shutil.rmtree(restore_root, ignore_errors=True)
    return results


def validate_report_paths(path: Path, markdown_path: Path) -> None:
    if path.resolve() == markdown_path.resolve():
        raise ValueError("Browsing QA receipt and markdown output paths must differ")


def write_receipt(path: Path, markdown_path: Path, executable: Path, results: list[dict]) -> None:
    validate_report_paths(path, markdown_path)
    for output in (path, markdown_path):
        if output.is_symlink():
            raise ValueError(f"Browsing QA output path must not be a symlink: {output}")
        if output.exists() and not output.is_file():
            raise ValueError(f"Browsing QA output path is not a regular file: {output}")
    receipt = {
        "verificationExecutable": str(executable),
        "clipBytes": len(Fixture.clip),
        "scenarios": results,
        "passed": suite_passed(results),
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(receipt, indent=2) + "\n")
    markdown_path.write_text(markdown_table(results))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "build/Shaar Verification.app")
    parser.add_argument("--receipt", type=Path, default=ROOT / "build/browsing-qa/receipt.json")
    parser.add_argument("--markdown", type=Path, default=ROOT / "build/browsing-qa/table.md")
    parser.add_argument("--scenarios", default="")
    options = parser.parse_args()
    try:
        scenarios = parse_scenarios(options.scenarios)
    except UnknownScenario as error:
        parser.error(str(error))
    try:
        validate_report_paths(options.receipt, options.markdown)
    except ValueError as error:
        parser.error(str(error))
    executable = options.app / "Contents/MacOS/ShaarVerification"
    if not executable.is_file():
        parser.error(f"Missing verification app: {executable}")
    with tempfile.TemporaryDirectory(prefix="shaar-browsing-qa-") as temporary:
        Fixture.slow_reload_requests = {}
        Fixture.icon = favicon_png()
        Fixture.clip = make_clip(Path(temporary))
        Fixture.heavy = page("heavy", "<div id=heavy>" + ("<div></div>" * 20000) + "</div>")
        with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            page_url = f"http://127.0.0.1:{server.server_port}/"

            def publish(current):
                write_receipt(options.receipt, options.markdown, executable, current)

            results = []
            try:
                results = run_suite(executable, scenarios, page_url, publish)
            finally:
                server.shutdown()
    write_receipt(options.receipt, options.markdown, executable, results)
    print(markdown_table(results))
    print(options.receipt)
    if not suite_passed(results):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
