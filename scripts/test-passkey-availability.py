#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Exercise WebAuthn availability in a hidden ad-hoc verification bundle.

The page reads isUserVerifyingPlatformAuthenticatorAvailable. It does not call
credentials.get or credentials.create. A signature that already has the browser
passkey entitlement or a keychain access group is refused before launch.
"""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading


ROOT = Path(__file__).resolve().parents[1]
CRASHES = Path.home() / "Library/Logs/DiagnosticReports"
BROWSER_ENTITLEMENT = "com.apple.developer.web-browser.public-key-credential"
KEYCHAIN_GROUPS = "keychain-access-groups"
EMPTY_TEAM_GROUP = ".com.arcusis.shaar.engine.webauthn"
TEAM_GROUP = "F9Z784RA6D.com.arcusis.shaar.engine.webauthn"


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/":
            self.send_error(404)
            return
        data = b"<!doctype html><meta charset=\"utf-8\"><title>Passkeys</title>\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *args):
        pass


def adhoc_without_passkey_entitlements(details: str, entitlements: str) -> str | None:
    """Return a refusal reason, or None when the availability probe may launch."""
    if "Signature=adhoc" not in details or "TeamIdentifier=not set" not in details:
        return "signature is not ad-hoc"
    if BROWSER_ENTITLEMENT in entitlements:
        return "browser passkey entitlement is present"
    if KEYCHAIN_GROUPS in entitlements:
        return "keychain-access-groups is present"
    return None


def crash_names():
    names = set()
    for directory in (CRASHES, CRASHES / "Retired"):
        if directory.is_dir():
            names.update(
                path.name for path in directory.iterdir()
                if path.suffix in {".ips", ".crash"}
                and path.name.startswith(("Shaar", "ArcusisBrowser", "Chromium"))
            )
    return names


def signature_text(path: Path) -> tuple[str, str]:
    details = subprocess.run(["codesign", "-dvv", str(path)], capture_output=True, text=True)
    entitlements = subprocess.run(
        ["codesign", "-d", "--entitlements", "-", "--xml", str(path)],
        capture_output=True, text=True,
    )
    if details.returncode != 0:
        raise SystemExit(f"Refusing to launch: codesign failed for {path}")
    return details.stderr, entitlements.stdout + "\n" + entitlements.stderr


def require_adhoc(path: Path) -> None:
    reason = adhoc_without_passkey_entitlements(*signature_text(path))
    if reason:
        raise SystemExit(f"Refusing to launch {path}: {reason}")


def contains_cstring(path: Path, needle: str) -> bool:
    """True when needle is its own NUL-terminated C string, not a suffix of a longer one."""
    target = b"\0" + needle.encode() + b"\0"
    extra = len(target) - 1
    previous = b""
    with path.open("rb") as handle:
        while True:
            block = handle.read(1024 * 1024)
            if not block:
                return target in previous
            window = previous + block
            if target in window:
                return True
            previous = window[-extra:]


def receipt_output_path(value: str) -> Path:
    path = Path(value)
    if path.is_symlink():
        raise argparse.ArgumentTypeError(f"receipt output must not be a symlink: {path}")
    if path.parent.is_symlink():
        raise argparse.ArgumentTypeError(f"receipt output parent must not be a symlink: {path.parent}")
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "build/Shaar Verification.app")
    parser.add_argument("--receipt", type=receipt_output_path,
                        default=ROOT / "build/passkey-availability/receipt.json")
    options = parser.parse_args()
    executable = options.app / "Contents/MacOS/ShaarVerification"
    framework = (
        options.app / "Contents/Frameworks/Chromium Framework.framework"
        / "Versions/Current/Chromium Framework"
    )
    if not executable.is_file() or not framework.is_file():
        parser.error(f"Missing shipping app: {options.app}")
    require_adhoc(options.app)
    require_adhoc(executable)
    before = crash_names()
    with ThreadingHTTPServer(("127.0.0.1", 0), Page) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        root = Path(tempfile.mkdtemp(prefix="arcusis-engine-probe-"))
        try:
            marker = root / ".arcusis-probe"
            marker.write_text("arcusis-engine-probe-v1\n")
            marker.chmod(0o600)
            home = root / "home"
            home.mkdir()
            report_path = root / "report.json"
            page = f"http://127.0.0.1:{server.server_port}/"
            environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home))
            environment["SHAAR_ENGINE_TESTING"] = "1"
            environment["SHAAR_MOCK_KEYCHAIN"] = "1"
            result = subprocess.run(
                [str(executable), "--passkey-availability", str(report_path), page],
                env=environment, capture_output=True, text=True, timeout=90, check=False,
            )
            report = json.loads(report_path.read_text()) if report_path.is_file() else {}
        finally:
            shutil.rmtree(root, ignore_errors=True)
        server.shutdown()
    crashes = sorted(crash_names() - before)
    engine = {
        "checksBrowserEntitlement": contains_cstring(framework, BROWSER_ENTITLEMENT),
        "emptyTeamAccessGroup": contains_cstring(framework, EMPTY_TEAM_GROUP),
        "teamAccessGroup": contains_cstring(framework, TEAM_GROUP),
    }
    passed = (
        result.returncode == 0 and report.get("passed") is True and report.get("passkey") == "false"
        and report.get("publicKeyCredential") is True and report.get("platformAuthenticator") is True
        and report.get("credentialsGet") is True and report.get("secureContext") is True
        and report.get("allWindowsHidden") is True and not crashes
    )
    receipt = {
        "verificationExecutable": str(executable), "exitCode": result.returncode,
        "passkey": report.get("passkey"), "publicKeyCredential": report.get("publicKeyCredential"),
        "platformAuthenticator": report.get("platformAuthenticator"),
        "conditionalMediation": report.get("conditionalMediation"),
        "credentialsGet": report.get("credentialsGet"), "secureContext": report.get("secureContext"),
        "allWindowsHidden": report.get("allWindowsHidden"), "rendererQuiet": report.get("rendererQuiet"),
        "engine": engine, "crashReports": crashes, "passed": passed,
    }
    options.receipt.parent.mkdir(parents=True, exist_ok=True)
    options.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))
    if not passed:
        if result.stderr:
            print(result.stderr[-4000:])
        if report.get("error"):
            print(report["error"])
        raise SystemExit(1)


if __name__ == "__main__":
    main()
