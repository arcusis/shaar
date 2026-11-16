#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Exercise password, card, and address save prompts in a hidden verification bundle."""

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import sqlite3
import subprocess
import tempfile
import threading
import time
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parents[1]
CRASHES = Path.home() / "Library/Logs/DiagnosticReports"
BUTTON = (
    '<button id="plain" type="submit">'
)
EXPECTED_SUBMISSIONS = {"/password", "/card", "/address"}
DIAGNOSTIC_PREFIX = "SHAAR_SAVE_PROMPT_DIAGNOSTIC "
TRUSTED_INPUT_FAILURE_PREFIX = "trusted input failed at "
TRUSTED_INPUT_FAILURE_STAGES = {
    "invalid fixture text request", "render surface unavailable",
    "engine request rejected", "engine reply not submitted",
    "tab ownership unavailable", "capture lease wait timed out",
    "target unavailable while waiting for capture lease", "target unavailable at start",
    "target unavailable before snapshot", "forced snapshot was empty",
    "tab disappeared after snapshot", "target unavailable after snapshot",
    "main frame unavailable after snapshot",
    "element point unavailable or outside view", "target unavailable at element point",
    "target unavailable before dispatch", "target unavailable before text commit",
    "capture timed out",
}
DIAGNOSTIC_STAGES = {
    "hook:password", "hook:card", "hook:address", "offer:entered",
    "offer:invalid-input", "offer:context-denied", "offer:no-profile-services",
    "offer:no-selected-regular-tab", "offer:invalid-page-url",
    "offer:serialize-failed", "offer:pending-limit", "offer:expiry-schedule-failed",
    "offer:event-emitted", "offer:event-rejected",
}
PROMPT_NAMES = (
    "password-save", "password-dismiss", "password-never",
    "card-save", "card-dismiss", "address-save", "address-dismiss",
)


class FixtureServer(ThreadingHTTPServer):
    def __init__(self, address, handler):
        super().__init__(address, handler)
        self.submissions = {}
        self.submission_lock = threading.Lock()

    def record_submission(self, referer):
        path = urlsplit(referer or "").path
        if path in EXPECTED_SUBMISSIONS:
            with self.submission_lock:
                self.submissions[path] = self.submissions.get(path, 0) + 1

    def submitted_forms(self):
        with self.submission_lock:
            return sorted(self.submissions)

    def submission_counts(self):
        with self.submission_lock:
            return dict(self.submissions)


class Fixture(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length:
            self.rfile.read(min(length, 65536))
        self.server.record_submission(self.headers.get("Referer"))
        self.path = "/saved"
        self.do_GET()

    def do_GET(self):
        page = self.path.split("?", 1)[0]
        if page == "/password":
            body = f"""<!doctype html><meta charset="utf-8"><title>Password</title>
<form action="/password" method="post" autocomplete="on">
<label for="username">Email or username</label>
<input id="username" name="username" autocomplete="username">
<label for="password">Password</label>
<input id="password" name="password" type="password" autocomplete="current-password">
{BUTTON}Sign in</button></form>"""
        elif page == "/login":
            body = """<!doctype html><meta charset="utf-8"><title>Login</title>
<form action="/login" method="post" autocomplete="on">
<label for="username">Email or username</label>
<input id="username" name="username" autocomplete="username">
<label for="password">Password</label>
<input id="password" name="password" type="password" autocomplete="current-password">
<button id="login-submit" type="submit">Sign in</button>
</form>"""
        elif page == "/card":
            body = f"""<!doctype html><meta charset="utf-8"><title>Card</title>
<form action="/card" method="post" autocomplete="on">
<label for="card-name">Name on card</label>
<input id="card-name" name="cc-name" autocomplete="cc-name">
<label for="card-number">Card number</label>
<input id="card-number" name="cc-number" inputmode="numeric" autocomplete="cc-number">
<label for="card-exp-month">Expiration month</label>
<input id="card-exp-month" name="cc-exp-month" autocomplete="cc-exp-month">
<label for="card-exp-year">Expiration year</label>
<input id="card-exp-year" name="cc-exp-year" autocomplete="cc-exp-year">
{BUTTON}Pay</button></form>"""
        elif page == "/address":
            body = f"""<!doctype html><meta charset="utf-8"><title>Address</title>
<form action="/address" method="post" autocomplete="on">
<label for="address-name">Full name</label>
<input id="address-name" name="name" autocomplete="name">
<label for="address-street">Street address</label>
<input id="address-street" name="street-address" autocomplete="street-address">
<label for="address-city">City</label>
<input id="address-city" name="address-level2" autocomplete="address-level2">
<label for="address-region">State</label>
<input id="address-region" name="address-level1" autocomplete="address-level1">
<label for="address-postal">Postal code</label>
<input id="address-postal" name="postal-code" autocomplete="postal-code">
<label for="address-country">Country</label>
<input id="address-country" name="country-name" autocomplete="country-name">
<label for="address-email">Email</label>
<input id="address-email" name="email" type="email" autocomplete="email">
{BUTTON}Save address</button></form>"""
        elif page == "/saved":
            body = "<!doctype html><title>Saved</title><main>submitted</main>"
        else:
            self.send_error(404)
            return
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *args):
        return


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


def copy_prompt_screenshots(source_dir, destination_dir):
    copied = {}
    for name in PROMPT_NAMES:
        source = source_dir / f"save-prompt-{name}.png"
        if not source.is_file() or source.is_symlink():
            continue
        destination = destination_dir / source.name
        destination_dir.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        copied[name] = str(destination)
    return copied


def screenshot_directory(receipt, locale):
    if locale not in {"en", "he"}:
        raise ValueError(f"Unsupported screenshot locale: {locale}")
    return receipt.parent / "screenshots" / locale


def trusted_input_failure_stages(output):
    stages = []
    for line in output.splitlines():
        if TRUSTED_INPUT_FAILURE_PREFIX not in line:
            continue
        stage = line.split(TRUSTED_INPUT_FAILURE_PREFIX, 1)[1].strip()
        if stage in TRUSTED_INPUT_FAILURE_STAGES:
            stages.append(stage)
    return stages


def safe_trusted_text_diagnostics(report):
    """Keep field outcomes while excluding DOM values and arbitrary report data."""
    diagnostics = report.get("trustedTextDiagnostics", [])
    if not isinstance(diagnostics, list):
        return []
    safe = []
    for diagnostic in diagnostics:
        if not isinstance(diagnostic, dict):
            continue
        fields = diagnostic.get("fields", [])
        safe_fields = []
        if isinstance(fields, list):
            for field in fields:
                if not isinstance(field, dict):
                    continue
                safe_fields.append({
                    key: field[key]
                    for key in ("id", "present", "valueMatches", "valueLength", "focused")
                    if key in field
                })
        safe.append({
            "valuesEntered": diagnostic.get("valuesEntered") is True,
            "fields": safe_fields,
            "activeElementIsInput": diagnostic.get("activeElementIsInput") is True,
            "activeInputType": diagnostic.get("activeInputType"),
        })
    return safe


def profile_autofill_preferences(data_root):
    """Read only the three booleans that gate password and Autofill offers."""
    evidence = []
    for path in sorted(data_root.rglob("Preferences")):
        if path.is_symlink() or not path.is_file():
            continue
        try:
            root = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(root, dict):
            continue
        autofill = root.get("autofill")
        if not isinstance(autofill, dict):
            autofill = {}
        values = {
            "credentialsEnableService": root.get("credentials_enable_service"),
            "autofillProfileEnabled": autofill.get("profile_enabled"),
            "autofillCreditCardEnabled": autofill.get("credit_card_enabled"),
        }
        if any(isinstance(value, bool) for value in values.values()):
            evidence.append({
                "profile": str(path.parent.relative_to(data_root)),
                **{key: value for key, value in values.items()
                   if isinstance(value, bool)},
            })
    return evidence


def profile_password_evidence(data_root, username, origin, profile_id=None):
    """Report whether Chromium persisted the fixture login without exposing secrets."""
    evidence = []
    for path in sorted(data_root.rglob("Login Data")):
        if path.is_symlink() or not path.is_file():
            continue
        row = {
            "profile": str(path.parent.relative_to(data_root)),
            "databasePresent": True,
            "fixtureCredentialStored": False,
            "matchesSaveProfile": bool(profile_id) and path.parent.name.lower()
            == f"profile {profile_id.lower()}",
        }
        try:
            connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=1)
            try:
                entries = connection.execute(
                    "SELECT origin_url, username_value, blacklisted_by_user, password_value "
                    "FROM logins WHERE origin_url LIKE ?",
                    (origin.rstrip("/") + "%",),
                ).fetchall()
                row["fixtureCredentialStored"] = any(
                    stored_username == username
                    and urlsplit(stored_origin).scheme == urlsplit(origin).scheme
                    and urlsplit(stored_origin).netloc == urlsplit(origin).netloc
                    and not blacklisted and bool(password)
                    for stored_origin, stored_username, blacklisted, password in entries
                )
                row["fixtureOriginLoginCount"] = len(entries)
                row["fixtureUsernameMatchCount"] = sum(
                    stored_username == username for _, stored_username, _, _ in entries
                )
                row["fixtureSecretPresent"] = any(
                    stored_username == username and bool(password)
                    for _, stored_username, _, password in entries
                )
                row["loginTableAvailable"] = True
            finally:
                connection.close()
        except (OSError, sqlite3.Error):
            row["loginTableAvailable"] = False
        evidence.append(row)
    return evidence


def saved_in_profile(evidence, profile_id):
    if not profile_id:
        return False
    expected_profile = f"profile {profile_id.lower()}"
    return any(
        entry.get("profile", "").lower() == expected_profile
        and entry.get("fixtureCredentialStored")
        for entry in evidence
    )


def password_save_profile_id(rows):
    """Read the saved profile from the save row, not the earlier dismiss row."""
    return next((row.get("saveProfileID") for row in rows
                 if row.get("name") == "password"), None)


def storage_diagnostics(output):
    evidence = []
    pattern = re.compile(r"oscrypt|safe storage|keychain|password.?store|addlogin|login data", re.I)
    for line in output.splitlines():
        if pattern.search(line):
            line = line.replace("parity-secret", "<fixture-secret>")
            line = line.replace("parity-user", "<fixture-user>")
            evidence.append(line[:500])
    return evidence


# Fields copied from the stored receipt onto stdout.
STDOUT_RECEIPT_FIELDS = (
    "verificationExecutable",
    "exitCode",
    "locale",
    "allWindowsHidden",
    "windowsOnScreen",
    "renderSurface",
    "rows",
    "submittedForms",
    "autofillPreferences",
    "submissionCounts",
    "diagnosticStages",
    "screenshots",
    "crashReports",
    "passed",
)


def redacted_stdout_summary(receipt):
    """Return receipt fields that are safe to print."""
    if not isinstance(receipt, dict):
        return {}
    return {key: receipt[key] for key in STDOUT_RECEIPT_FIELDS if key in receipt}


def write_receipt_and_print_summary(path, receipt):
    """Store the full receipt, then print a redacted summary of that file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(receipt, indent=2) + "\n")
    stored = json.loads(path.read_text())
    print(json.dumps(redacted_stdout_summary(stored), indent=2))


def verification_keychain_evidence(app):
    try:
        with (app / "Contents/Info.plist").open("rb") as stream:
            mock_requested = plistlib.load(stream).get("ShaarUseMockKeychain") is True
    except (OSError, plistlib.InvalidFileException):
        mock_requested = False
    try:
        keychain_item = subprocess.run(
            ["/usr/bin/security", "find-generic-password", "-s", "Shaar Safe Storage",
             "-a", "Shaar"], capture_output=True, timeout=3, check=False,
        ).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        keychain_item = False
    return {
        "verificationBundleRequestsMockKeychain": mock_requested,
        "hostShaarSafeStorageItemAvailable": keychain_item,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, default=ROOT / "build/Shaar Verification.app")
    parser.add_argument("--receipt", type=Path, default=ROOT / "build/save-prompt/receipt.json")
    parser.add_argument(
        "--locale", choices=("en", "he"),
        default=os.environ.get("SHAAR_V02_PROOF_LOCALE", "en"),
    )
    parser.add_argument(
        "--password-only", action="store_true",
        help="Run only the password-save and revisit scenario.",
    )
    options = parser.parse_args()
    executable = options.app / "Contents/MacOS/ShaarVerification"
    if not executable.is_file():
        parser.error(f"Missing verification app: {executable}")
    before = crash_names()
    screenshots = {}
    autofill_preferences = []
    password_evidence = []
    save_profile_id = None
    keychain_evidence = verification_keychain_evidence(options.app)
    with FixtureServer(("127.0.0.1", 0), Fixture) as server, FixtureServer(
        ("127.0.0.1", 0), Fixture
    ) as never_server:
        threads = [
            threading.Thread(target=instance.serve_forever, daemon=True)
            for instance in (server, never_server)
        ]
        for thread in threads:
            thread.start()
        root = Path(tempfile.mkdtemp(prefix="arcusis-engine-probe-"))
        try:
            marker = root / ".arcusis-probe"
            marker.write_text("arcusis-engine-probe-v1\n")
            marker.chmod(0o600)
            home = root / "home"
            home.mkdir()
            report_path = root / "report.json"
            page = f"http://127.0.0.1:{server.server_address[1]}"
            never_page = f"http://127.0.0.1:{never_server.server_address[1]}"
            environment = os.environ.copy()
            environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home),
                               SHAAR_ENGINE_TESTING="1", SHAAR_MOCK_KEYCHAIN="1")
            command = [
                str(executable), "--enable-logging=stderr", "--log-level=0",
                "--probe-data-dir", str(root),
                "--save-prompt-probe", str(report_path), page, never_page,
            ]
            if options.password_only:
                command.append("--password-only")
            if options.locale == "he":
                command.extend(["-AppleLanguages", "(he)"])
            else:
                command.extend(["-AppleLanguages", "(en)"])
            result = subprocess.run(
                command,
                env=environment, capture_output=True, text=True, timeout=180, check=False,
            )
            report = json.loads(report_path.read_text()) if report_path.is_file() else {}
            save_profile_id = password_save_profile_id(report.get("rows", []))
            diagnostics = []
            combined_output = result.stdout + "\n" + result.stderr
            trusted_input_failures = trusted_input_failure_stages(combined_output)
            for line in combined_output.splitlines():
                if DIAGNOSTIC_PREFIX not in line:
                    continue
                stage = line.split(DIAGNOSTIC_PREFIX, 1)[1].strip()
                if stage in DIAGNOSTIC_STAGES:
                    diagnostics.append(stage)
        finally:
            screenshots = copy_prompt_screenshots(
                root, screenshot_directory(options.receipt, options.locale)
            )
            autofill_preferences = profile_autofill_preferences(root / "Chromium")
            password_evidence = profile_password_evidence(
                root / "Chromium", "parity-user",
                f"http://127.0.0.1:{server.server_address[1]}/",
                save_profile_id,
            )
            shutil.rmtree(root, ignore_errors=True)
        server.shutdown()
        never_server.shutdown()
        deadline = time.monotonic() + 3
        while set(server.submitted_forms()) != EXPECTED_SUBMISSIONS and time.monotonic() < deadline:
            time.sleep(0.05)
        submitted_forms = sorted(
            set(server.submitted_forms()) | set(never_server.submitted_forms()))
        submission_counts = {}
        for instance in (server, never_server):
            for path, count in instance.submission_counts().items():
                submission_counts[path] = submission_counts.get(path, 0) + count
    crashes = sorted(crash_names() - before)
    expected_submissions = {"/password"} if options.password_only else EXPECTED_SUBMISSIONS
    receipt = {
        "verificationExecutable": str(executable), "exitCode": result.returncode,
        "locale": options.locale,
        "passwordOnly": options.password_only,
        "allWindowsHidden": report.get("allWindowsHidden"),
        "windowsOnScreen": report.get("windowsOnScreen"),
        "renderSurface": report.get("renderSurface"),
        "rows": report.get("rows", []), "submittedForms": submitted_forms,
        "trustedTextDiagnostics": safe_trusted_text_diagnostics(report),
        "storageDiagnostics": storage_diagnostics(combined_output),
        "autofillPreferences": autofill_preferences,
        "passwordStoreEvidence": password_evidence,
        "passwordSaveStoredInSaveProfile": saved_in_profile(password_evidence, save_profile_id),
        "keychainEvidence": keychain_evidence,
        "submissionCounts": submission_counts,
        "diagnosticStages": diagnostics,
        "trustedInputFailures": trusted_input_failures,
        "screenshots": screenshots,
        "crashReports": crashes,
        "passed": result.returncode == 0 and report.get("passed") is True
        and set(submitted_forms) == expected_submissions
        and submission_counts == (
            {"/password": 1} if options.password_only
            else {"/password": 4, "/card": 2, "/address": 2}
        )
        and set(screenshots) == (
            {"password-save"} if options.password_only else set(PROMPT_NAMES)
        )
        and saved_in_profile(password_evidence, save_profile_id)
        and not crashes,
    }
    write_receipt_and_print_summary(options.receipt, receipt)
    if not receipt["passed"]:
        if result.stderr:
            print(result.stderr[-4000:])
        raise SystemExit(1)


if __name__ == "__main__":
    main()
