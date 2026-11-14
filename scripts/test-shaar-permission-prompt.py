#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Hidden website permission probe for Shaar Verification.app.

Camera and microphone must still show the existing sheet. Geolocation,
notifications, MIDI, and protocol-handler registration are the same loopback
pages used by the platform parity probe. Exit 0 when all four prompts appear
from the engine. Exit 2 when the run completed and those prompts are still
absent. A protocol result does not count without a protocolHandler request.
Launch through shaar-heavy.
"""

import argparse
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading

CRASHES = Path.home() / "Library/Logs/DiagnosticReports"
BUTTON = (
    '<button id="parity-action" style="position:fixed;left:8px;top:8px;'
    'width:180px;height:48px">Run</button>'
)
SCRIPT_HEAD = """
function finish(result) { window.parityResult = result; }
function fail(error) {
  finish({
    outcome: 'rejected',
    name: error && error.name ? error.name : 'Error',
    message: error && error.message ? String(error.message) : String(error)
  });
}
"""
PAGES = {
    "media": """
      document.getElementById('parity-action').onclick = () => {
        navigator.mediaDevices.getUserMedia({audio:true, video:true}).then(stream => {
          const audio = stream.getAudioTracks().length;
          const video = stream.getVideoTracks().length;
          stream.getTracks().forEach(track => track.stop());
          finish({outcome:'resolved', audio, video});
        }).catch(fail);
      };
    """,
    "geolocation": """
      document.getElementById('parity-action').onclick = () => {
        navigator.geolocation.getCurrentPosition(
          position => finish({outcome:'resolved', latitude:position.coords.latitude}),
          error => finish({outcome:'rejected', code:error.code, message:error.message}),
          {timeout:4000, maximumAge:0});
      };
    """,
    "notifications": """
      document.getElementById('parity-action').onclick = () => {
        Notification.requestPermission().then(state => finish({outcome:'resolved', state})).catch(fail);
      };
    """,
    "midi": """
      document.getElementById('parity-action').onclick = () => {
        if (!navigator.requestMIDIAccess) { finish({outcome:'missing'}); return; }
        navigator.requestMIDIAccess({sysex:false})
          .then(access => finish({outcome:'resolved', inputs:access.inputs.size})).catch(fail);
      };
    """,
    "protocol": """
      document.getElementById('parity-action').onclick = () => {
        try {
          navigator.registerProtocolHandler('web+shaarparity', location.origin + '/handled?u=%s');
          finish({outcome:'registered'});
        } catch (error) { fail(error); }
      };
    """,
    "mailto": """
      document.getElementById('parity-action').onclick = () => {
        try {
          navigator.registerProtocolHandler('mailto', location.origin + '/handled?u=%s');
          finish({outcome:'registered'});
        } catch (error) { fail(error); }
      };
    """,
    "handled": "finish({outcome:'handled', href:location.href});",
}


def page(title, body, script):
    return (
        "<!doctype html><meta charset=utf-8>"
        f"<title>{title}</title>{body}<script>{SCRIPT_HEAD}{script}</script>"
    )


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        route = self.path.split("?", 1)[0].strip("/")
        script = PAGES.get(route)
        if script is None:
            self.send_error(404)
            return
        body = "" if route == "handled" else BUTTON
        data = page(route, body, script).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_args):
        return


def dishonest_protocol(checks):
    for check in checks:
        if check.get("name") not in {"protocol", "mailto"} or not check.get("prompted"):
            continue
        kinds = set(check.get("kinds") or [])
        if "protocolHandler" not in kinds:
            return True
        if check.get("externalScheme"):
            return True
        handled = str(check.get("handledURL") or "")
        if handled.startswith("web+"):
            return True
    return False


def crash_names():
    if not CRASHES.is_dir():
        return set()
    return {item.name for item in CRASHES.iterdir() if "Shaar" in item.name or "shaar" in item.name}


def evidence_directory(value: str) -> Path:
    path = Path(value)
    if path.is_symlink():
        raise argparse.ArgumentTypeError(f"evidence directory must not be a symlink: {path}")
    if path.parent.is_symlink():
        raise argparse.ArgumentTypeError(
            f"evidence directory parent must not be a symlink: {path.parent}")
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--evidence", required=True, type=evidence_directory)
    options = parser.parse_args()
    app = options.app.resolve()
    evidence = options.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    before = crash_names()
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        with tempfile.TemporaryDirectory(prefix="shaar-permission-") as temporary:
            root = Path(temporary)
            data = root / "arcusis-engine-probe-permission"
            data.mkdir(mode=0o700)
            marker = data / ".arcusis-probe"
            marker.write_text("arcusis-engine-probe-v1\n")
            marker.chmod(0o600)
            home = root / "home"
            home.mkdir()
            report = root / "report.json"
            framework = app / "Contents/Frameworks/Chromium Framework.framework"
            command = [
                str(app / "Contents/MacOS/ShaarVerification"),
                "--probe-website-permission",
                "--probe-framework", str(framework),
                "--probe-output", str(report),
                "--probe-data-dir", str(data),
                "--probe-fixture-url", f"http://127.0.0.1:{server.server_port}/",
            ]
            environment = dict(
                os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home),
                SHAAR_ENGINE_TESTING="1", RUNNER_TEMP=str(root))
            try:
                process = subprocess.run(
                    command, env=environment, capture_output=True, text=True,
                    timeout=150, check=False)
            except subprocess.TimeoutExpired as error:
                print(json.dumps({"timeout": True, "stderr": str(error)[-2000:]}))
                raise SystemExit(1)
            if report.exists():
                shutil.copyfile(report, evidence / "report.json")
            for image in root.glob("*.png"):
                shutil.copyfile(image, evidence / image.name)
            (evidence / "stderr.txt").write_text(process.stderr[-8000:])
            payload = json.loads(report.read_text()) if report.exists() else {}
            new_crashes = sorted(crash_names() - before)
            prompted = set(payload.get("prompts") or [])
            required = {"geolocation", "notifications", "midi", "protocol"}
            summary = {
                "exitCode": process.returncode,
                "passed": payload.get("passed"),
                "mediaPrompted": payload.get("mediaPrompted"),
                "mediaTracks": payload.get("mediaTracks"),
                "allWindowsHidden": payload.get("allWindowsHidden"),
                "prompts": sorted(prompted),
                "missingPrompts": sorted(required - prompted),
                "newCrashes": new_crashes,
                "error": payload.get("error", ""),
            }
            print(json.dumps(summary, indent=2))
            completed = (
                process.returncode in (0, 1) and not new_crashes
                and payload.get("mediaPrompted") and payload.get("mediaTracks")
                and payload.get("allWindowsHidden")
                and not payload.get("unexpectedSurfaces")
                and not payload.get("error"))
            opened_protocols = set(payload.get("openedProtocols") or [])
            expected_protocols = {"web+shaarparity", "mailto"}
            if not completed:
                raise SystemExit(1)
            if dishonest_protocol(payload.get("checks") or []):
                raise SystemExit(1)
            if (
                not payload.get("passed")
                or required - prompted
                or expected_protocols - opened_protocols
            ):
                raise SystemExit(2)
        server.shutdown()


if __name__ == "__main__":
    main()
