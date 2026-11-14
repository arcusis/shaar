#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Verify pinned Chromium language against an owned loopback fixture and disposable profiles."""

import argparse
import http.server
import json
import os
import plistlib
import re
import shlex
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import engine_fixture


ROOT = Path(__file__).resolve().parents[1]
APP = Path(os.environ.get("SHAAR_VERIFICATION_APP", ROOT / "build/Shaar Verification.app"))
MARKER = ".arcusis-localization-probe"
BACKTRACE_SETTING = "enable=yes,interactive=no,color=no,output-to=stderr,limit=128,top=0"


def safe_environment():
    allowed = ("PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "SDKROOT", "TOOLCHAINS")
    return {key: os.environ[key] for key in allowed if key in os.environ}


def redact(text):
    text = re.sub(r"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+", r"\1[REDACTED]", text)
    return re.sub(r"\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{20,})\b", "[REDACTED]", text)


def run_engine_probe(arguments, environment):
    started = time.time()
    environment = dict(environment)
    if os.environ.get("SHAAR_LOCALIZATION_BACKTRACE") == "1":
        environment["SWIFT_BACKTRACE"] = BACKTRACE_SETTING
    process = subprocess.Popen(
        arguments, cwd=ROOT, env=environment, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=240)
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate()
        raise
    completed = subprocess.CompletedProcess(arguments, process.returncode, stdout, stderr)
    return completed, process.pid, started


def crashpad_dumps_for(profile_root, since):
    marker = profile_root / MARKER
    try:
        if marker.read_text(encoding="utf-8") != "arcusis-localization-probe-v1\n":
            return []
        database = (profile_root / "Chromium" / "Crashpad").resolve(strict=True)
        if not database.is_relative_to(profile_root.resolve(strict=True)):
            return []
    except OSError:
        return []
    candidates = []
    for state in ("pending", "completed"):
        for path in (database / state).glob("*.dmp"):
            try:
                source = path.resolve(strict=True)
                details = source.stat()
            except OSError:
                continue
            if not source.is_relative_to(database) or not (0 < details.st_size <= 20_000_000):
                continue
            if details.st_mtime >= since:
                candidates.append((details.st_mtime, source))
    return [path for _, path in sorted(candidates, reverse=True)[:4]]


def localization_crash_reports_for(pid, since):
    """Find this probe's .ips report across user and system report directories."""
    roots = (
        Path.home() / "Library/Logs/DiagnosticReports",
        Path("/Library/Logs/DiagnosticReports"),
    )
    candidates = set()
    for root in roots:
        for directory in (root, root / "Retired"):
            try:
                candidates.update(path for path in directory.glob("*.ips"))
            except OSError:
                continue
    matches = []
    for path in candidates:
        try:
            details = path.stat()
            if details.st_mtime < since or not (0 < details.st_size <= 20_000_000):
                continue
            _, body = path.read_text(errors="replace").split("\n", 1)
            report = json.loads(body)
        except (OSError, ValueError):
            continue
        if isinstance(report, dict) and report.get("pid") == pid:
            matches.append((details.st_mtime, path))
    return [path for _, path in sorted(matches, reverse=True)[:4]]


def record_failed_probe(case_name, output, completed, pid, started, artifact):
    artifact.mkdir(parents=True, exist_ok=True)
    stderr = redact(completed.stderr)
    reports = []
    if completed.returncode < 0:
        engine_fixture.wait_until(
            lambda: bool(localization_crash_reports_for(pid, started)),
            engine_fixture.CRASH_REPORT_SETTLE_SECONDS,
        )
        reports = localization_crash_reports_for(pid, started)
    for index, source in enumerate(reports):
        try:
            shutil.copyfile(source, artifact / f"{case_name}-crash-{index + 1}.ips")
        except OSError:
            continue
    crashpad_dumps = []
    if completed.returncode < 0:
        for index, source in enumerate(crashpad_dumps_for(output.parent, started), start=1):
            try:
                shutil.copyfile(source, artifact / f"{case_name}-crashpad-{index}.dmp")
                crashpad_dumps.append(source.name)
            except OSError:
                continue
    if output.exists():
        shutil.copyfile(output, artifact / f"{case_name}-probe.json")
    (artifact / f"{case_name}-stderr.log").write_text(
        stderr[-2_000_000:], encoding="utf-8",
    )
    receipt = {
        "case": case_name, "pid": pid, "exitCode": completed.returncode,
        "probeReportWritten": output.exists(),
        "crashReports": [Path(path).name for path in reports],
        "crashpadDumps": crashpad_dumps,
        "stderrTail": stderr[-4000:],
    }
    (artifact / f"{case_name}-failure.json").write_text(
        json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8",
    )


class FixtureState:
    def __init__(self, root):
        self.root = root
        self.lock = threading.Lock()
        self.requests = {}
        self.documents = {}


def handler_for(state):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            parsed = urlsplit(self.path)
            query = parse_qs(parsed.query)
            language = query.get("language", [""])[0]
            phase = query.get("phase", [""])[0]
            case_name = query.get("case", [""])[0]
            if parsed.path != "/ack" or language not in ("en", "he") or phase not in ("initial", "restart") or not case_name:
                self.send_error(400)
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                document = json.loads(self.rfile.read(length))
            except (ValueError, json.JSONDecodeError):
                self.send_error(400)
                return
            with state.lock:
                state.documents[case_name] = document
            self.respond(200, b"ok", "text/plain")

        def do_GET(self):
            parsed = urlsplit(self.path)
            query = parse_qs(parsed.query)
            language = query.get("language", [""])[0]
            phase = query.get("phase", [""])[0]
            case_name = query.get("case", [""])[0]
            if language not in ("en", "he") or phase not in ("initial", "restart") or not case_name:
                self.send_error(400)
                return
            if parsed.path != "/":
                self.send_error(404)
                return
            with state.lock:
                state.requests.setdefault(case_name, []).append(
                    self.headers.get("Accept-Language", "")
                )
            direction = "rtl" if language == "he" else "ltr"
            page = f"""<!doctype html><html data-arcusis-fixture="v1" lang="{language}" dir="{direction}">
<meta charset="utf-8"><title>Shaar localization fixture</title>
<body><main>Loopback localization fixture</main><script>
fetch('/ack?language={language}&phase={phase}&case={case_name}', {{method:'POST',cache:'no-store',
headers:{{'Content-Type':'application/json'}},body:JSON.stringify({{language:navigator.language,
languages:Array.from(navigator.languages),htmlLanguage:document.documentElement.lang,
htmlDirection:document.documentElement.dir}})}}).catch(()=>{{}});
</script></body></html>""".encode()
            self.respond(200, page, "text/html; charset=utf-8")

        def respond(self, status, body, content_type):
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                # The probe can quit after recording its receipt, before reading the ACK.
                pass

        def log_message(self, *_):
            return

    return Handler


def run():
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-build", action="store_true")
    options = parser.parse_args()
    if not options.skip_build:
        real_swift = shutil.which("swift")
        if not real_swift:
            raise RuntimeError("Swift toolchain not found")
        real_swift = str(Path(real_swift).resolve())
        with tempfile.TemporaryDirectory(prefix="shaar-localization-swift-") as wrapper_root:
            wrapper_dir = Path(wrapper_root)
            wrapper = wrapper_dir / "swift"
            wrapper.write_text(
                "#!/bin/bash\n"
                f"if [[ \"$1\" == build ]]; then exec {shlex.quote(real_swift)} \"$@\" --jobs 1; fi\n"
                f"exec {shlex.quote(real_swift)} \"$@\"\n",
                encoding="utf-8",
            )
            wrapper.chmod(0o700)
            environment = safe_environment()
            environment["PATH"] = str(wrapper_dir) + os.pathsep + environment.get("PATH", "")
            subprocess.run(
                ["bash", "scripts/bundle-app.sh", "--with-engine", "--verification"],
                cwd=ROOT, env=environment, check=True,
            )
    executable = APP / "Contents/MacOS/ShaarVerification"
    if not executable.is_file():
        raise RuntimeError(f"verification executable missing: {executable}")

    outer = Path(tempfile.mkdtemp(prefix="arcusis-localization-probe-")).resolve()
    # A unique app domain exercises the real picker setter across process launches without
    # touching the installed browser's preferences or another verification run's defaults.
    isolated_app = outer / "Localization.app"
    subprocess.run(["cp", "-cR", str(APP), str(isolated_app)], check=True)
    info_path = isolated_app / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    domain = f"com.arcusis.localization-fixture.{uuid.uuid4().hex}"
    info["CFBundleIdentifier"] = domain
    info_path.write_bytes(plistlib.dumps(info))
    sign_command = ["codesign", "--force", "--timestamp=none", "--sign", "-"]
    if os.environ.get("SHAAR_LOCALIZATION_BACKTRACE") == "1":
        entitlements = outer / "backtrace-entitlements.plist"
        entitlements.write_bytes(plistlib.dumps({"com.apple.security.get-task-allow": True}))
        sign_command.extend(["--entitlements", str(entitlements)])
    subprocess.run([*sign_command, str(isolated_app)], check=True, capture_output=True)
    executable = isolated_app / "Contents/MacOS/ShaarVerification"

    def store_selection(selection):
        subprocess.run([str(executable), "--probe-store-language", selection],
                       env=safe_environment(), check=True, capture_output=True, timeout=30)
        stored = plistlib.loads(subprocess.check_output(["defaults", "export", domain, "-"]))
        if stored.get("BrowserLanguage.selection") != selection:
            raise RuntimeError("Picker selection did not persist in the isolated app domain")
        if selection != "systemDefault" and stored.get("AppleLanguages") != [selection]:
            raise RuntimeError("Picker AppleLanguages override did not persist")

    state = FixtureState(outer)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler_for(state))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    reports = []
    roots = {}
    artifact = ROOT / "build/Verification/localization-engine-evidence"
    for name in ("english", "hebrew", "language-switch"):
        profile_root = outer / name
        profile_root.mkdir(mode=0o700)
        (profile_root / MARKER).write_text("arcusis-localization-probe-v1\n", encoding="utf-8")
        (profile_root / ".arcusis-probe").write_text("arcusis-engine-probe-v1\n", encoding="utf-8")
        roots[name] = profile_root
    scenarios = [
        ("english", "en", "initial", "english-first-launch", "fresh launch", "en", None),
        ("english", "en", "restart", "english-restart", "same-language restart", None, None),
        ("hebrew", "he", "initial", "hebrew-first-launch", "fresh launch", "he", None),
        ("hebrew", "he", "restart", "hebrew-restart", "same-language restart", None, None),
        ("language-switch", "en", "initial", "switch-profile-english-first", "switch profile first launch", "en", None),
        ("language-switch", "en", "restart", "switch-profile-english-restart", "switch profile restart", None, None),
        ("language-switch", "he", "restart", "switch-profile-to-hebrew", "existing-profile language switch", "he", None),
        ("language-switch", "en", "restart", "switch-profile-back-to-english", "existing-profile language switch back", "en", None),
        ("language-switch", "en", "restart", "english-over-macos-hebrew", "explicit choice over macOS per-app language", "en", "he"),
        ("language-switch", "he", "restart", "system-restores-macos-hebrew", "System restores macOS per-app language", "systemDefault", None),
    ]
    try:
        for root_name, language, phase, case_name, relation, selection, system_language in scenarios:
            if system_language:
                store_selection("systemDefault")
                subprocess.run(["defaults", "write", domain, "AppleLanguages", "-array", system_language],
                               check=True, capture_output=True)
            if selection is not None:
                store_selection(selection)
            stored = plistlib.loads(subprocess.check_output(["defaults", "export", domain, "-"]))
            profile_root = roots[root_name]
            output = profile_root / f"{case_name}.json"
            url = f"http://127.0.0.1:{server.server_port}/?language={language}&phase={phase}&case={case_name}"
            arguments = [
                str(executable), "--probe-data-dir", str(profile_root), "--probe-url", url,
                "--probe-phase", phase, "--probe-output", str(output), "--probe-localization",
            ]
            environment = safe_environment()
            (profile_root / "Downloads").mkdir(mode=0o700, exist_ok=True)
            completed, pid, started = run_engine_probe(arguments, environment)
            if completed.returncode != 0 or not output.exists():
                record_failed_probe(case_name, output, completed, pid, started, artifact)
                raise RuntimeError(
                    f"{language} {phase} engine probe failed ({completed.returncode}): "
                    f"{redact(completed.stderr)[-1200:]}"
                )
            report = json.loads(output.read_text(encoding="utf-8"))
            deadline = time.monotonic() + 15
            while case_name not in state.documents and time.monotonic() < deadline:
                time.sleep(0.05)
            requests = state.requests.get(case_name, [])
            document = state.documents.get(case_name)
            expected_direction = "rtl" if language == "he" else "ltr"
            if not report.get("passed") or report.get("probeMode") != "localization-only":
                raise RuntimeError(f"{language} {phase}: probe report failed or wrong mode")
            if len(requests) < 2 or not all(
                value.split(",", 1)[0].strip().split("-", 1)[0] == language for value in requests
            ):
                raise RuntimeError(f"{language} {phase}: loopback Accept-Language mismatch")
            if not isinstance(document, dict):
                raise RuntimeError(f"{language} {phase}: browser language receipt missing/mismatched")
            navigator = document.get("language")
            languages = document.get("languages")
            if (not isinstance(navigator, str) or navigator.split("-", 1)[0] != language
                    or not isinstance(languages, list) or not languages
                    or not isinstance(languages[0], str)
                    or languages[0].split("-", 1)[0] != language):
                raise RuntimeError(f"{language} {phase}: browser language receipt missing/mismatched")
            if document.get("htmlLanguage") != language or document.get("htmlDirection") != expected_direction:
                raise RuntimeError(f"{language} {phase}: fixture document lang/dir mismatch")
            reports.append({"case": case_name, "language": language, "phase": phase,
                            "profileRelation": relation,
                            "storedSelection": stored.get("BrowserLanguage.selection"),
                            "storedAppleLanguages": stored.get("AppleLanguages"),
                            "acceptLanguage": sorted(set(requests)),
                            "checks": report.get("checks", [])})
            print(f"{case_name}: persisted choice, navigator, direction, Accept-Language passed")
        receipt = outer / "localization-evidence.json"
        receipt.write_text(json.dumps(reports, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        artifact.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(receipt, artifact / "localization-evidence.json")
        print(f"Localization evidence: {artifact / 'localization-evidence.json'}")
    finally:
        server.shutdown()
        server.server_close()
        subprocess.run(["defaults", "delete", domain], capture_output=True, check=False)
        shutil.rmtree(isolated_app)


if __name__ == "__main__":
    run()
