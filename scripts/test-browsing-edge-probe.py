#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Part B hidden browsing probe for Shaar Verification.app.

Covers heavy pages, dialogs, popups, downloads, sad-tab and hang recovery,
unreachable hosts, HTTP errors, find in page, zoom, and print. Part A owns
tab overload, windows, private windows, restore, and splits.
"""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import threading
import time


ROOT = Path(__file__).resolve().parents[1]
CRASHES = Path.home() / "Library/Logs/DiagnosticReports"
SLOW_BYTES = 256 * 1024
HUGE_NODES = 15000


def page(title, ready, body):
    return f"""<!doctype html><html data-ready="{ready}"><head><meta charset="utf-8">
<title>{title}</title></head><body>{body}</body></html>""".encode()


FIND = page("Find", "find", """
<p>alpha OrbitFindMarker beta</p>
<p>OrbitFindMarker gamma</p>
<p>delta OrbitFindMarker</p>""")

HUGE = page("Huge", "pending", f"""
<div id="root"></div>
<script>
const root = document.getElementById("root");
const fragment = document.createDocumentFragment();
for (let index = 0; index < {HUGE_NODES}; index += 1) {{
  const row = document.createElement("div");
  row.textContent = "row " + index;
  if (index === {HUGE_NODES - 1}) row.id = "last-row";
  fragment.appendChild(row);
}}
root.appendChild(fragment);
document.documentElement.dataset.ready = "huge";
</script>""")

SCROLL = page("Scroll", "pending", """
<div id="root" style="height:220px;overflow:auto"></div>
<div id="page-scroll-spacer" style="height:180vh"></div>
<script>
const root = document.getElementById("root");
function add(count) {
  for (let index = 0; index < count; index += 1) {
    const row = document.createElement("div");
    row.textContent = "scroll " + root.children.length;
    row.style.height = "36px";
    root.appendChild(row);
  }
}
add(40);
window.__frames = 0;
window.__scrollEvents = 0;
window.__scrollEndEvents = 0;
window.__pageScrollEvents = 0;
window.addEventListener("scroll", function () {
  window.__pageScrollEvents += 1;
});
root.addEventListener("scroll", function () {
  window.__scrollEvents += 1;
  if (root.scrollTop + root.clientHeight >= root.scrollHeight - 80) add(400);
});
root.addEventListener("scrollend", function () {
  window.__scrollEndEvents += 1;
});
requestAnimationFrame(function tick() {
  window.__frames += 1;
  if (window.__frames < 5) requestAnimationFrame(tick);
});
document.documentElement.dataset.ready = "scroll";
</script>""")

MEDIA = page("Media", "pending", """
<canvas id="gl" width="64" height="64"></canvas>
<video id="clip" muted playsinline style="width:64px;height:64px"></video>
<script>
const report = {webgl: false, video: false, error: ""};
try {
  const canvas = document.getElementById("gl");
  const gl = canvas.getContext("webgl");
  if (!gl) throw new Error("no webgl");
  gl.clearColor(0.2, 0.4, 0.6, 1);
  gl.clear(gl.COLOR_BUFFER_BIT);
  const pixel = new Uint8Array(4);
  gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, pixel);
  report.webgl = true;
  report.pixel = Array.from(pixel);
  report.vendor = String(gl.getParameter(gl.VENDOR));
  const paint = document.createElement("canvas");
  paint.width = 64;
  paint.height = 64;
  const context = paint.getContext("2d");
  context.fillStyle = "#224466";
  context.fillRect(0, 0, 64, 64);
  const video = document.getElementById("clip");
  video.srcObject = paint.captureStream(15);
  const played = video.play();
  report.videoPending = true;
  Promise.resolve(played).then(function () {
    report.video = !video.paused && video.videoWidth > 0 && video.readyState >= 2;
    report.videoWidth = video.videoWidth;
    report.videoHeight = video.videoHeight;
    report.paused = video.paused;
    window.__edgeMedia = report;
    document.documentElement.dataset.ready = "media";
  }, function (error) {
    report.error = String(error);
    window.__edgeMedia = report;
    document.documentElement.dataset.ready = "media";
  });
} catch (error) {
  report.error = String(error);
  window.__edgeMedia = report;
  document.documentElement.dataset.ready = "media";
}
window.__edgeMedia = report;
</script>""")

MEMORY = page("Memory", "pending", """
<p id="marker">memory</p>
<script>
try {
  const hog = [];
  const chunk = 8 * 1024 * 1024;
  let bytes = 0;
  for (let index = 0; index < 24; index += 1) {
    const buffer = new Uint8Array(chunk);
    for (let offset = 0; offset < chunk; offset += 4096) buffer[offset] = 7;
    hog.push(buffer);
    bytes += chunk;
  }
  window.__hog = hog;
  document.documentElement.dataset.bytes = String(bytes);
} catch (error) {
  document.documentElement.dataset.error = String(error);
  document.documentElement.dataset.bytes = "0";
}
document.documentElement.dataset.ready = "memory";
</script>""")

DIALOGS = page("Dialogs", "dialogs", """
<button id="performance-input" style="position:fixed;left:8px;top:8px;width:140px;height:44px">Arm</button>
<input id="blank" type="file" style="position:fixed;left:8px;top:64px;width:180px;height:44px">
<script>
document.getElementById("performance-input").addEventListener("click", function () {
  window.addEventListener("beforeunload", function (event) {
    event.preventDefault();
    event.returnValue = "leave";
  });
  document.documentElement.dataset.armed = "1";
});
</script>""")

POPUPS = page("Popups", "popups", """
<a id="blank" target="_blank" href="/popup-dest" style="position:fixed;left:8px;top:8px;padding:16px">New tab</a>
<button id="popup" style="position:fixed;left:8px;top:64px;width:140px;height:44px"
 onclick="window.open('/popup-dest', '_blank')">Open window</button>""")

POPUP_DEST = page("Popup destination", "popup-dest", "<main id='destination'>Popup destination loaded</main>")

DOWNLOAD = page("Download", "download", """
<a id="popup" href="/files/small.txt" download="edge-small.txt"
 style="position:fixed;left:8px;top:8px;padding:16px;background:white">Download</a>""")

HANG = page("Hang", "pending", """
<p id="marker">hang</p>
<script>
window.__edgeReady = true;
document.documentElement.dataset.ready = "hang";
setTimeout(function () {
  const start = Date.now();
  while (Date.now() - start < 8000) {}
}, 300);
</script>""")

CRASH = page("Crash", "crash", "<p id='marker'>crash-target</p>")

HTTP_404 = b"edge-http-404 the page was not found"
HTTP_500 = b"edge-http-500 the server failed"
SMALL = b"edge-small-ok\n"
SLOW_PREFIX = b"edge-download-ok\n"


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/find":
            return self.bytes(FIND, "text/html; charset=utf-8")
        if path == "/huge":
            return self.bytes(HUGE, "text/html; charset=utf-8")
        if path == "/scroll":
            return self.bytes(SCROLL, "text/html; charset=utf-8")
        if path == "/media":
            return self.bytes(MEDIA, "text/html; charset=utf-8")
        if path == "/memory":
            return self.bytes(MEMORY, "text/html; charset=utf-8")
        if path == "/dialogs":
            return self.bytes(DIALOGS, "text/html; charset=utf-8")
        if path == "/popups":
            return self.bytes(POPUPS, "text/html; charset=utf-8")
        if path == "/popup-dest":
            return self.bytes(POPUP_DEST, "text/html; charset=utf-8")
        if path == "/download":
            return self.bytes(DOWNLOAD, "text/html; charset=utf-8")
        if path == "/hang":
            return self.bytes(HANG, "text/html; charset=utf-8")
        if path == "/crash":
            return self.bytes(CRASH, "text/html; charset=utf-8")
        if path == "/http/404":
            return self.bytes(HTTP_404, "text/plain; charset=utf-8", status=404)
        if path == "/http/500":
            return self.bytes(HTTP_500, "text/plain; charset=utf-8", status=500)
        if path == "/auth":
            body = b"auth required"
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="Edge"')
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if path == "/files/small.txt":
            return self.attachment(SMALL, "edge-small.txt")
        if path == "/files/slow.bin":
            return self.slow()
        self.send_error(404)

    def attachment(self, body, name):
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", f'attachment; filename="{name}"')
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def slow(self):
        payload = SLOW_PREFIX + b"x" * (SLOW_BYTES - len(SLOW_PREFIX))
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", 'attachment; filename="edge-slow.bin"')
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        view = memoryview(payload)
        offset = 0
        try:
            while offset < len(view):
                self.wfile.write(view[offset:offset + 4096])
                self.wfile.flush()
                offset += 4096
                time.sleep(0.25)
        except (BrokenPipeError, ConnectionResetError):
            return

    def bytes(self, body, content_type, status=200):
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
    for directory in (CRASHES, CRASHES / "Retired"):
        if not directory.is_dir():
            continue
        for path in directory.iterdir():
            if path.suffix in {".ips", ".crash"} and path.name.startswith(
                ("Shaar", "ArcusisBrowser", "Chromium")
            ):
                names.add(path.name)
    return names


def crash_process(name):
    for directory in (CRASHES, CRASHES / "Retired"):
        path = directory / name
        if not path.is_file():
            continue
        try:
            lines = path.read_text(errors="replace").splitlines()
            if len(lines) < 2 or not lines[1].startswith("{"):
                return {"unreadable": True}
            body = json.loads("\n".join(lines[1:]))
        except (OSError, json.JSONDecodeError):
            return {"unreadable": True}
        if not isinstance(body, dict):
            return {"unreadable": True}
        return {
            "pid": body.get("pid"),
            "parentPid": body.get("parentPid"),
            "signal": (body.get("exception") or {}).get("signal"),
        }
    return {}


def crash_is_owned(info, app_pid, launcher_pid):
    if info.get("unreadable"):
        return True
    pid = info.get("pid")
    parent = info.get("parentPid")
    if app_pid is not None and (pid == app_pid or parent == app_pid):
        return True
    return launcher_pid is not None and parent == launcher_pid


def owned_crash(name, app_pid, launcher_pid):
    return crash_is_owned(crash_process(name), app_pid, launcher_pid)


def browser_crash(name, app_pid, launcher_pid):
    if "Helper" in name:
        return False
    if not (
        name.startswith("ArcusisBrowser")
        or name.startswith("ShaarVerification")
        or name.startswith("Shaar-")
        or name.startswith("Shaar ")
    ):
        return False
    return owned_crash(name, app_pid, launcher_pid)


def row_accepted(row):
    return row.get("passed") is True and row.get("proven") is not False


def report_passed(rows):
    return bool(rows) and all(row_accepted(row) for row in rows)


def visible_notes(dialogs):
    return [note for note in dialogs or [] if note.get("kind") == "visible"]


def visible_notes_fail_their_row(rows, dialogs):
    flashed = visible_notes(dialogs)
    if not flashed:
        return True
    hidden = [row for row in rows if row.get("name") == "Hidden windows"]
    return bool(hidden) and all(row.get("passed") is False for row in hidden)


def note_cap_fails_its_row(rows, dialogs_truncated):
    if not dialogs_truncated:
        return True
    hidden = [row for row in rows if row.get("name") == "Hidden windows"]
    return bool(hidden) and all(row.get("passed") is False for row in hidden)


def process_stayed_up(finished_report, return_code, timed_out, quit_hung):
    clean_exit = return_code == 0 and not timed_out and not quit_hung
    return bool(finished_report) and clean_exit


def evaluate_gate(product_rows, dialogs, harness_row, dialogs_truncated=False):
    return (
        report_passed(product_rows)
        and visible_notes_fail_their_row(product_rows, dialogs)
        and note_cap_fails_its_row(product_rows, dialogs_truncated)
        and row_accepted(harness_row)
    )


def markdown_table(rows):
    lines = ["## Part B", "", "| Check | Result | Detail |", "| --- | --- | --- |"]
    for row in rows:
        result = "PASS" if row_accepted(row) else "FAIL"
        detail = " ".join(str(row.get("detail", "")).split())
        if len(detail) > 220:
            detail = detail[:217] + "..."
        detail = detail.replace("|", "/")
        lines.append(f"| {row.get('name', '')} | {result} | {detail} |")
    return "\n".join(lines)


def stop(process):
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


def validate_receipt_path(path, app=None):
    if path.parent.is_symlink():
        raise ValueError(f"receipt directory must not be a symlink: {path.parent}")
    if path.is_symlink():
        raise ValueError(f"receipt path must not be a symlink: {path}")
    if path.exists() and not path.is_file():
        raise ValueError(f"receipt path is not a regular file: {path}")
    if app is not None:
        try:
            path.resolve().relative_to(app.resolve())
        except ValueError:
            pass
        else:
            raise ValueError(f"receipt path must be outside the verification app: {path}")


def write_receipt(path, receipt, app=None):
    validate_receipt_path(path, app)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(receipt, indent=2) + "\n")


def read_report(path):
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def collect_output(process, report_path, timeout=660, quit_grace=15):
    captured = {}

    def read():
        _stdout, stderr = process.communicate()
        captured["stderr"] = stderr

    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    deadline = time.monotonic() + timeout
    complete_at = None
    quit_hung = False
    timed_out = False
    while process.poll() is None and time.monotonic() < deadline:
        if read_report(report_path).get("complete") is True:
            if complete_at is None:
                complete_at = time.monotonic()
            elif time.monotonic() - complete_at >= quit_grace:
                quit_hung = True
                break
        else:
            complete_at = None
        time.sleep(0.5)
    if process.poll() is None:
        if not quit_hung:
            timed_out = True
        stop(process)
    reader.join(timeout=20)
    return_code = process.returncode if process.returncode is not None else 1
    return return_code, captured.get("stderr") or "", timed_out, quit_hung


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "build/Shaar Verification.app")
    parser.add_argument("--receipt", type=Path, default=ROOT / "build/browsing-edge/receipt.json")
    options = parser.parse_args()
    try:
        validate_receipt_path(options.receipt, options.app)
    except ValueError as error:
        parser.error(str(error))
    executable = options.app / "Contents/MacOS/ShaarVerification"
    if not executable.is_file():
        parser.error(f"Missing verification app: {executable}")
    before = crash_names()
    report = {}
    return_code = 1
    timed_out = False
    quit_hung = False
    stderr = ""
    root = None
    gate = False
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        root = Path(tempfile.mkdtemp(prefix="arcusis-engine-probe-"))
        root.chmod(0o700)
        process = None
        try:
            marker = root / ".arcusis-probe"
            marker.write_text("arcusis-engine-probe-v1\n")
            marker.chmod(0o600)
            home = root / "home"
            home.mkdir(mode=0o700)
            report_path = root / "report.json"
            page_url = f"http://127.0.0.1:{server.server_port}/find"
            environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home))
            environment["SHAAR_ENGINE_TESTING"] = "1"
            environment["SHAAR_MOCK_KEYCHAIN"] = "1"
            process = subprocess.Popen(
                [str(executable), "--browsing-edge-probe", str(report_path), page_url],
                env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                start_new_session=True,
            )
            return_code, stderr, timed_out, quit_hung = collect_output(process, report_path)
            report = read_report(report_path)
        except Exception as error:
            stderr = (stderr or "") + f"\nharness error: {error}"
        finally:
            if process is not None:
                stop(process)
            server.shutdown()
        crashes = sorted(crash_names() - before)
        app_pid = process.pid if process is not None else None
        browser = [
            name for name in crashes
            if browser_crash(name, app_pid, os.getpid())
        ]
        helper = [
            name for name in crashes
            if name not in browser and "Helper" in name and owned_crash(name, app_pid, os.getpid())
        ]
        product_rows = list(report.get("rows") or [])
        finished_report = report.get("complete") is True and not browser
        app_finished = process_stayed_up(finished_report, return_code, timed_out, quit_hung)
        harness_row = {
            "name": "Browser process stayed up",
            "passed": app_finished,
            "proven": True,
            "detail": (
                f"exit {return_code}, timedOut {timed_out}, quitHung {quit_hung}, "
                f"browser reports {len(browser)}, helper reports {len(helper)}"
            ),
        }
        rows = product_rows + [harness_row]
        gate = evaluate_gate(
            product_rows, report.get("dialogs") or [], harness_row,
            report.get("dialogsTruncated") is True)
        receipt = {
            "verificationExecutable": str(executable),
            "exitCode": return_code,
            "timedOut": timed_out,
            "quitHung": quit_hung,
            "allWindowsHidden": report.get("allWindowsHidden"),
            "dialogsTruncated": report.get("dialogsTruncated") is True,
            "dialogSampleIntervalMs": report.get("dialogSampleIntervalMs"),
            "complete": report.get("complete"),
            "rows": rows,
            "dialogs": report.get("dialogs") or [],
            "browserCrashReports": browser,
            "helperCrashReports": helper,
            "stderrTail": (stderr or "")[-4000:],
            "passed": gate,
        }
        write_receipt(options.receipt, receipt, options.app)
        print(markdown_table(rows))
        print()
        print(json.dumps({
            "receipt": str(options.receipt),
            "passed": receipt["passed"],
            "appFinished": app_finished,
            "exitCode": return_code,
            "timedOut": timed_out,
            "browserCrashReports": browser,
            "helperCrashReports": helper,
        }, indent=2))
        if root is not None:
            shutil.rmtree(root, ignore_errors=True)
    if not gate:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
