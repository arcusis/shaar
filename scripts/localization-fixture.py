#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Verify pinned Chromium language against an owned loopback fixture and disposable profiles."""

import argparse
import http.server
import json
import os
import re
import shlex
import shutil
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from urllib.parse import parse_qs, urlsplit


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "build/Shaar Verification.app"
MARKER = ".arcusis-localization-probe"


def safe_environment():
    allowed = ("PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "SDKROOT", "TOOLCHAINS")
    return {key: os.environ[key] for key in allowed if key in os.environ}


def redact(text):
    text = re.sub(r"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+", r"\1[REDACTED]", text)
    return re.sub(r"\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{20,})\b", "[REDACTED]", text)


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
    state = FixtureState(outer)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler_for(state))
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    reports = []
    roots = {}
    for name in ("english", "hebrew", "language-switch"):
        profile_root = outer / name
        profile_root.mkdir(mode=0o700)
        (profile_root / MARKER).write_text("arcusis-localization-probe-v1\n", encoding="utf-8")
        (profile_root / ".arcusis-probe").write_text("arcusis-engine-probe-v1\n", encoding="utf-8")
        roots[name] = profile_root
    scenarios = [
        ("english", "en", "initial", "english-first-launch", "fresh launch"),
        ("english", "en", "restart", "english-restart", "same-language restart"),
        ("hebrew", "he", "initial", "hebrew-first-launch", "fresh launch"),
        ("hebrew", "he", "restart", "hebrew-restart", "same-language restart"),
        ("language-switch", "en", "initial", "switch-profile-english-first", "switch profile first launch"),
        ("language-switch", "en", "restart", "switch-profile-english-restart", "switch profile restart"),
        ("language-switch", "he", "restart", "switch-profile-to-hebrew", "existing-profile language switch"),
        ("language-switch", "en", "restart", "switch-profile-back-to-english", "existing-profile language switch back"),
    ]
    try:
        for root_name, language, phase, case_name, relation in scenarios:
                profile_root = roots[root_name]
                output = profile_root / f"{case_name}.json"
                url = f"http://127.0.0.1:{server.server_port}/?language={language}&phase={phase}&case={case_name}"
                arguments = [
                    str(executable), "--probe-data-dir", str(profile_root), "--probe-url", url,
                    "--probe-phase", phase, "--probe-output", str(output), "--probe-localization",
                    "-BrowserLanguage.selection", language,
                ]
                environment = safe_environment()
                environment["ARDIA_DOWNLOADS_DIR"] = str(profile_root / "Downloads")
                environment["ARDIA_BACKGROUND"] = "picture-in-picture"
                (profile_root / "Downloads").mkdir(mode=0o700, exist_ok=True)
                completed = subprocess.run(
                    arguments, cwd=ROOT, env=environment, capture_output=True, text=True,
                    timeout=240,
                )
                if completed.returncode != 0 or not output.exists():
                    raise RuntimeError(
                        f"{language} {phase} engine probe failed ({completed.returncode}): "
                        f"{redact(completed.stderr[-1200:])}"
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
                if not requests or not all(
                    value.split(",", 1)[0].strip().split("-", 1)[0] == language for value in requests
                ):
                    raise RuntimeError(f"{language} {phase}: loopback Accept-Language mismatch")
                if not isinstance(document, dict) or document.get("language") != language:
                    raise RuntimeError(f"{language} {phase}: browser language receipt missing/mismatched")
                if document.get("htmlLanguage") != language or document.get("htmlDirection") != expected_direction:
                    raise RuntimeError(f"{language} {phase}: fixture document lang/dir mismatch")
                reports.append({"case": case_name, "language": language, "phase": phase,
                                "profileRelation": relation,
                                "acceptLanguage": sorted(set(requests)),
                                "checks": report.get("checks", [])})
                print(f"{case_name}: navigator, document direction, Accept-Language passed")
        receipt = outer / "localization-evidence.json"
        receipt.write_text(json.dumps(reports, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        artifact = ROOT / "build/Verification/localization-engine-evidence"
        artifact.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(receipt, artifact / "localization-evidence.json")
        print(f"Localization evidence: {artifact / 'localization-evidence.json'}")
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    run()
