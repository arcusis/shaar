#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Exercise Shaar DevTools in the shipping bundle, hidden and offscreen."""

import argparse
from base64 import b64decode
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading


FRAMEWORKS = (
    Path(__file__).resolve().parents[1] / "ThirdParty/InspectorFixtures/frameworks.js"
)
PIXEL = b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)
PAGE = b"""<!doctype html><html><head><meta charset="utf-8">
<title>Shaar DevTools QA</title>
<style>
  body { font: 16px Arial, sans-serif; margin: 0; color: #172033; background: #fff; }
  .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; padding: 16px; }
  .row { display: flex; gap: 8px; align-items: center; }
  img { width: 48px; height: 48px; }
  #long div { padding: 4px 8px; border-bottom: 1px solid #e5e7eb; }
</style></head><body>
<main class="grid">
  <section class="row" id="react-root"></section>
  <section id="vue-root"></section>
  <section id="svelte-root"></section>
  <img src="/pixel.png" alt="QA pixel">
</main>
<div id="long"></div>
<script src="/frameworks.js"></script>
<script>
const long = document.getElementById("long");
for (let index = 0; index < 120; index += 1) {
  const row = document.createElement("div");
  row.textContent = "QA row " + index;
  long.appendChild(row);
}
console.log("qa-log");
console.error(new Error("qa-error"));
localStorage.setItem("qa-local", "ready");
sessionStorage.setItem("qa-session", "ready");
fetch("/api/items", {cache: "no-store"}).catch(function () {});
const xhr = new XMLHttpRequest();
xhr.open("GET", "/api/xhr");
xhr.send();
(async function () {
  try {
    const database = await new Promise(function (resolve, reject) {
      const request = indexedDB.open("qa-db", 1);
      request.onupgradeneeded = function () {
        request.result.createObjectStore("notes");
      };
      request.onsuccess = function () { resolve(request.result); };
      request.onerror = function () { reject(request.error); };
    });
    const transaction = database.transaction("notes", "readwrite");
    transaction.objectStore("notes").put("ready", "qa-note");
    await new Promise(function (resolve, reject) {
      transaction.oncomplete = resolve;
      transaction.onerror = function () { reject(transaction.error); };
    });
    const cache = await caches.open("qa-cache");
    await cache.put("/pixel.png", new Response("cached", {status: 200}));
    await navigator.serviceWorker.register("/sw.js");
    window.__qaReady = true;
  } catch (error) {
    window.__qaError = String(error);
    window.__qaReady = true;
  }
})();
</script></body></html>"""
WORKER = b"""self.addEventListener("install", function (event) {
  event.waitUntil(caches.open("qa-cache").then(function (cache) {
    return cache.add("/pixel.png");
  }));
});
self.addEventListener("activate", function (event) {
  event.waitUntil(self.clients.claim());
});
"""
AWAY = b"<!doctype html><title>Away</title><p>Navigated away.</p>"


class Fixture(BaseHTTPRequestHandler):
    frameworks = b""
    hits = []

    def do_GET(self):
        Fixture.hits.append(self.path.split("?", 1)[0])
        path = self.path.split("?", 1)[0]
        if path in {"/qa", "/qa/"}:
            self.page(PAGE, "text/html; charset=utf-8", cookie=True)
            return
        if path == "/away":
            self.page(AWAY, "text/html; charset=utf-8")
            return
        if path == "/frameworks.js":
            self.page(self.frameworks, "text/javascript; charset=utf-8")
            return
        if path == "/sw.js":
            self.page(WORKER, "text/javascript; charset=utf-8")
            return
        if path == "/pixel.png":
            self.page(PIXEL, "image/png")
            return
        if path == "/api/items":
            self.page(b'{"items":[{"name":"alpha"}]}', "application/json")
            return
        if path == "/api/xhr":
            self.page(b"xhr-ok", "text/plain; charset=utf-8")
            return
        self.send_error(404)

    def page(self, body, content_type, cookie=False):
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        if cookie:
            self.send_header("Set-Cookie", "qa-cookie=ready; Path=/; SameSite=Lax")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *args):
        return


def crash_names():
    names = set()
    home = Path.home() / "Library/Logs/DiagnosticReports"
    for directory in (home, home / "Retired"):
        if not directory.is_dir():
            continue
        for path in directory.iterdir():
            if path.suffix in {".ips", ".crash"}:
                names.add(path.name)
    return names


def relevant(names):
    prefixes = ("ArcusisBrowser", "Shaar", "Chromium")
    return sorted(name for name in names if name.startswith(prefixes))


@contextmanager
def disposable_root():
    root = Path(tempfile.mkdtemp(prefix="shaar-devtools-smoke-"))
    try:
        yield root
    finally:
        shutil.rmtree(root, ignore_errors=True)


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_APP = ROOT / "build/Shaar.app"
SMOKE_SOURCES = (
    ROOT / "Sources/ArcusisBrowser/ShaarDevToolsSmoke.swift",
    ROOT / "Sources/ArcusisBrowser/ShaarDevToolsSmokeLook.swift",
    ROOT / "Sources/ArcusisBrowser/ArcusisBrowser.swift",
)


def binary_has_flag(executable: Path, flag: bytes) -> bool:
    if not executable.is_file():
        return False
    with executable.open("rb") as handle:
        previous = b""
        while True:
            block = handle.read(1024 * 1024)
            if not block:
                return False
            if flag in previous + block:
                return True
            previous = block[-len(flag):]


def sources_newer_than(executable: Path) -> bool:
    built = executable.stat().st_mtime
    return any(path.is_file() and path.stat().st_mtime > built for path in SMOKE_SOURCES)


def swift_is_busy() -> bool:
    for name in ("swift-frontend", "swift-build"):
        if subprocess.run(["pgrep", "-x", name], capture_output=True).returncode == 0:
            return True
    return False


def ensure_app(app: Path, rebuild: bool) -> Path:
    executable = app / "Contents/MacOS/ArcusisBrowser"
    reusable = (
        not rebuild
        and binary_has_flag(executable, b"--devtools-smoke")
        and not sources_newer_than(executable)
    )
    if reusable:
        print(f"Reusing {app}", flush=True)
        return app
    if app != DEFAULT_APP:
        raise SystemExit(f"{executable} is not a shipping bundle with --devtools-smoke")
    if swift_is_busy():
        raise SystemExit("Another Swift build is running. Refusing to start a second one.")
    print("Building the shipping bundle with scripts/bundle-app.sh --with-engine", flush=True)
    environment = dict(os.environ, SHAAR_BUNDLE_SWIFT_JOBS="4")
    built = subprocess.run(
        ["nice", "-n", "10", "bash", "scripts/bundle-app.sh", "--with-engine"],
        cwd=ROOT, env=environment, check=False,
    )
    if built.returncode != 0 or not binary_has_flag(executable, b"--devtools-smoke"):
        raise SystemExit(f"Shipping bundle did not gain --devtools-smoke (exit {built.returncode})")
    return app


SEVERITIES = ("crash", "broken", "wrong", "polish", "ok")


def severity_of(step):
    raw = step.get("severity")
    if raw in SEVERITIES:
        return raw
    return "ok" if step.get("passed") is True else "broken"


def print_table(steps):
    print("| Result | Severity | Panel | Action | Detail |", flush=True)
    print("| --- | --- | --- | --- | --- |", flush=True)
    for step in steps:
        result = "PASS" if step.get("passed") is True else "FAIL"
        panel = str(step.get("panel") or "Other").replace("|", "/")
        action = str(step.get("action") or step.get("name") or "").replace("|", "/")
        detail = str(step.get("detail") or "").replace("|", "/").replace("\n", " ")
        print(
            f"| {result} | {severity_of(step)} | {panel} | {action} | {detail} |",
            flush=True,
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=DEFAULT_APP)
    parser.add_argument("--receipt", type=Path, default=ROOT / "build/devtools-smoke/receipt.json")
    parser.add_argument("--screenshots", type=Path, default=ROOT / "build/devtools-smoke/screenshots")
    parser.add_argument("--rebuild", action="store_true")
    options = parser.parse_args()
    app = ensure_app(options.app.resolve(), options.rebuild)
    executable = app / "Contents/MacOS/ArcusisBrowser"
    if not FRAMEWORKS.is_file():
        parser.error(f"Component fixture is missing: {FRAMEWORKS}")
    Fixture.frameworks = FRAMEWORKS.read_bytes()
    before = crash_names()
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        with disposable_root() as root:
            home = root / "home"
            home.mkdir()
            report_path = root / "report.json"
            page = f"http://127.0.0.1:{server.server_port}/qa"
            environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home))
            environment.pop("SHAAR_ENGINE_TESTING", None)
            stdout_path = root / "stdout.txt"
            stderr_path = root / "stderr.txt"
            stdout_handle = stdout_path.open("w")
            stderr_handle = stderr_path.open("w")
            try:
                try:
                    result = subprocess.run(
                        [str(executable), "--devtools-smoke", str(report_path), page],
                        env=environment, stdout=stdout_handle, stderr=stderr_handle,
                        text=True, timeout=600, check=False,
                    )
                except subprocess.TimeoutExpired:
                    result = subprocess.CompletedProcess(
                        [str(executable)], 124, "", "timed out after 600s")
            finally:
                stdout_handle.close()
                stderr_handle.close()
            stderr_text = stderr_path.read_text(errors="replace") if stderr_path.is_file() else ""
            report = json.loads(report_path.read_text()) if report_path.is_file() else {}
            if not report_path.is_file():
                report = {
                    "passed": False,
                    "passedCount": 0,
                    "failedCount": 1,
                    "steps": [{
                        "panel": "Session",
                        "action": "Write report",
                        "passed": False,
                        "detail": f"The shipping app exited {result.returncode} without a report",
                    }],
                }
            shots = sorted(path.name for path in root.glob("panel-*.png"))
            if options.screenshots is not None:
                options.screenshots.mkdir(parents=True, exist_ok=True)
                for path in root.glob("panel-*.png"):
                    shutil.copy2(path, options.screenshots / path.name)
            crashes = relevant(crash_names() - before)
            steps = report.get("steps", [])
            if not isinstance(steps, list):
                steps = []
            for name in crashes:
                steps.append({
                    "panel": "Session",
                    "action": "Crash report",
                    "passed": False,
                    "severity": "crash",
                    "detail": name,
                })
            if result.returncode == 124:
                steps.append({
                    "panel": "Session",
                    "action": "Harness timeout",
                    "passed": False,
                    "severity": "broken",
                    "detail": "The packaged smoke timed out after 600s",
                })
            elif (result.returncode < 0 or result.returncode in {134, 139}) and not crashes:
                steps.append({
                    "panel": "Session",
                    "action": "Crash report",
                    "passed": False,
                    "severity": "crash",
                    "detail": f"Process exit {result.returncode}",
                })
            passed_count = sum(1 for step in steps if step.get("passed") is True)
            failed_count = len(steps) - passed_count
            counts = {name: 0 for name in SEVERITIES}
            for step in steps:
                if step.get("passed") is True:
                    continue
                counts[severity_of(step)] += 1
            receipt = {
                "exitCode": result.returncode,
                "passed": report.get("passed") is True and not crashes and result.returncode == 0,
                "passedCount": passed_count,
                "failedCount": failed_count,
                "severityCounts": counts,
                "normalBundle": report.get("normalBundle", ""),
                "steps": steps,
                "screenshots": shots,
                "crashes": crashes,
                "stderrTail": stderr_text[-2000:],
            }
            options.receipt.parent.mkdir(parents=True, exist_ok=True)
            options.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
            print_table(steps)
            print("Fixture hits: " + ", ".join(Fixture.hits), flush=True)
            print(
                "Summary: "
                f"{passed_count} passed, {failed_count} failed "
                f"(crash {counts['crash']}, broken {counts['broken']}, "
                f"wrong {counts['wrong']}, polish {counts['polish']}), "
                f"exit {result.returncode}, crashes {len(crashes)}",
                flush=True,
            )
            if crashes:
                print("Crashes: " + ", ".join(crashes), flush=True)
            bundle = report.get("normalBundle")
            if (
                result.returncode
                or report.get("passed") is not True
                or crashes
                or bundle not in {"com.arcusis.browser", "com.arcusis.browser.engine-preview"}
            ):
                raise SystemExit(1)
        server.shutdown()


if __name__ == "__main__":
    main()
