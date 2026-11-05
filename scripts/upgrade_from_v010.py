#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Headless v0.1.0 Ardia to Shaar migration on a disposable macOS runner."""

import argparse
from contextlib import contextmanager
import getpass
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import signal
import sqlite3
import subprocess
import tarfile
import tempfile
import threading
import urllib.request
from urllib.parse import urlsplit
import uuid
import zipfile


ROOT = Path(__file__).resolve().parents[1]
RELEASE = ROOT / "scripts/sparkle-fixture.json"
ALPHA = "c766672e-ab82-4f84-8ed3-2c6d75aeb1d1"
BETA = "f29a09f3-faf9-4938-a25b-260f67f42cc3"
PROFILES = {"alpha": ALPHA, "beta": BETA}


def require_disposable_runner(environment, username):
    runner_temp = environment.get("RUNNER_TEMP")
    if environment.get("GITHUB_ACTIONS") != "true" or username != "runner" or not runner_temp:
        raise RuntimeError("Upgrade test requires a disposable macOS runner, never a personal account")
    path = Path(runner_temp).resolve(strict=True)
    if not path.is_dir() or path.stat().st_uid != os.getuid():
        raise RuntimeError("Upgrade test requires an owned RUNNER_TEMP")
    return path


def check_isolated_home(root, environment):
    root = Path(root).resolve(strict=True)
    home = root / "home"
    if environment.get("HOME") != str(home) or environment.get("CFFIXED_USER_HOME") != str(home):
        raise RuntimeError("Upgrade test requires its exact temporary HOME")
    if not home.is_dir() or home.is_symlink() or home.stat().st_uid != os.getuid():
        raise RuntimeError("Upgrade test requires an owned temporary HOME")
    return home


def replace_once(source, old, new, label):
    if source.count(old) != 1:
        raise RuntimeError(f"v0.1.0 {label} source changed")
    return source.replace(old, new)


def remove_mock_keychain_switch(source):
    return replace_once(source, '    strings.push_back("--use-mock-keychain");\n', "",
                        "bridge")


def add_legacy_bookmarks(source):
    marker = "        try runtime.openTabID(sharedA, profileID: profileA, url: fixture.absoluteString)"
    addition = """        for (profile, account) in [(profileA, "alpha"), (profileB, "beta")] {
          let title = account == "alpha" ? "Alpha console" : "Beta console"
          let operation: [String: Any] = [
            "op": "add", "id": UUID().uuidString, "parent": "bar", "k": "u",
            "t": title, "u": fixture.absoluteString,
          ]
          try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            runtime.applyBookmarkOperation(operation, profileID: profile) { error in
              if let error { continuation.resume(throwing: error) }
              else { continuation.resume() }
            }
          }
          try expect(true, "v0.1.0 saved the \\(account) bookmark through Ardia")
        }
"""
    return replace_once(source, marker, addition + marker, "bookmark probe")


def add_hidden_window_guard(source):
    source = replace_once(source, "import Foundation\n", "import AppKit\nimport Foundation\n",
                          "main import")
    old = "    exit(EngineProbe.run(arguments: CommandLine.arguments))"
    new = """    NSApplication.shared.setActivationPolicy(.prohibited)
    let windowGuard = try! HiddenWindowOrderGuard.install()
    let result = EngineProbe.run(arguments: CommandLine.arguments)
    windowGuard.restore()
    exit(result)"""
    return replace_once(source, old, new, "main entrypoint")


def run_checked(arguments, *, cwd=None, env=None, timeout=900, output=None):
    process = subprocess.Popen(arguments, cwd=cwd, env=env, start_new_session=True,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        transcript, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        transcript, _ = process.communicate()
        if output is not None:
            Path(output).write_text(transcript)
        raise RuntimeError(f"{Path(arguments[0]).name} timed out; log: {output}") from None
    if output is not None:
        Path(output).write_text(transcript)
    if process.returncode:
        raise RuntimeError(f"{Path(arguments[0]).name} failed ({process.returncode}); log: {output}")
    return transcript


def fetch_release_zip(destination):
    release = json.loads(RELEASE.read_text())
    if release["tag"] != "v0.1.0" or release["commit"] != "f887d5d7308670fd3c2215ebe4814abe457afa0f":
        raise RuntimeError("Pinned v0.1.0 release metadata changed")
    digest = hashlib.sha256()
    size = 0
    with urllib.request.urlopen(release["url"], timeout=60) as source, destination.open("xb") as target:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
            size += len(chunk)
            if size > release["size"]:
                raise RuntimeError("v0.1.0 archive exceeded its pinned size")
            target.write(chunk)
    if size != release["size"] or digest.hexdigest() != release["sha256"]:
        raise RuntimeError("v0.1.0 release archive checksum mismatch")
    with zipfile.ZipFile(destination) as archive:
        if "Shaar.app/Contents/Info.plist" not in archive.namelist():
            raise RuntimeError("v0.1.0 release archive has no Shaar app")
    return release


def v010_commit():
    return run_checked(["git", "rev-parse", "v0.1.0^{commit}"], cwd=ROOT).strip()


def extract_old_source(destination, release):
    commit = v010_commit()
    if commit != release["commit"]:
        raise RuntimeError("Local v0.1.0 tag differs from the pinned release")
    archive = destination.parent / "v010-source.tar"
    with archive.open("wb") as target:
        subprocess.run(["git", "archive", "--format=tar", "v0.1.0"], cwd=ROOT,
                       stdout=target, check=True)
    destination.mkdir()
    with tarfile.open(archive) as source:
        source.extractall(destination, filter="data")


def prepare_old_harness(source, released_framework):
    bridge = source / "Sources/ChromiumBridge/ChromiumBridge.mm"
    bridge.write_text(remove_mock_keychain_switch(bridge.read_text()))
    probe = source / "Sources/ShaarVerification/EngineProbe.swift"
    probe.write_text(add_legacy_bookmarks(probe.read_text()))
    main = source / "Sources/ShaarVerification/ShaarVerificationMain.swift"
    main.write_text(add_hidden_window_guard(main.read_text()))
    shutil.copy2(ROOT / "Sources/ShaarVerification/HiddenWindowOrderGuard.swift",
                 source / "Sources/ShaarVerification/HiddenWindowOrderGuard.swift")
    bundle = source / "scripts/bundle-app.sh"
    bundle.write_text(replace_once(bundle.read_text(),
                                   "  swift build --manifest-cache none",
                                   "  swift build --jobs 4 --manifest-cache none",
                                   "bundle jobs"))
    fetch = source / "scripts/fetch-engine.sh"
    fetch.write_text("#!/bin/bash\nset -euo pipefail\nprintf '%s\\n' " +
                     json.dumps(str(released_framework)) + "\n")


def set_shipping_bundle_id(app):
    info_path = app / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    info["CFBundleIdentifier"] = "com.arcusis.browser"
    info_path.write_bytes(plistlib.dumps(info))
    run_checked(["codesign", "--force", "--timestamp=none", "--sign", "-", str(app)])
    run_checked(["codesign", "--verify", "--deep", "--strict", str(app)])


@contextmanager
def throwaway_keychain(root, environment):
    keychain = root / "upgrade.keychain-db"
    password = secrets.token_urlsafe(28)
    old_list = run_checked(["security", "list-keychains", "-d", "user"],
                           env=environment).splitlines()
    old_list = [item.strip().strip('"') for item in old_list]
    old_default = run_checked(["security", "default-keychain", "-d", "user"],
                              env=environment).strip().strip('"')
    run_checked(["security", "create-keychain", "-p", password, str(keychain)],
                env=environment)
    try:
        run_checked(["security", "unlock-keychain", "-p", password, str(keychain)],
                    env=environment)
        run_checked(["security", "set-keychain-settings", "-lut", "21600", str(keychain)],
                    env=environment)
        run_checked(["security", "list-keychains", "-d", "user", "-s", str(keychain)],
                    env=environment)
        run_checked(["security", "default-keychain", "-d", "user", "-s", str(keychain)],
                    env=environment)
        secret = secrets.token_urlsafe(24)
        run_checked(["security", "add-generic-password", "-a", "Ardia", "-s",
                     "Ardia Safe Storage", "-w", secret, "-A", str(keychain)],
                    env=environment)
        yield keychain, secret
    finally:
        run_checked(["security", "default-keychain", "-d", "user", "-s", old_default],
                    env=environment)
        run_checked(["security", "list-keychains", "-d", "user", "-s", *old_list],
                    env=environment)
        run_checked(["security", "delete-keychain", str(keychain)], env=environment)


def keychain_secret(keychain, service, account, environment):
    return run_checked(["security", "find-generic-password", "-a", account,
                        "-s", service, "-w", str(keychain)], env=environment).rstrip("\n")


def fixture_root_from_log(log, parent):
    matches = re.findall(r"^Probe evidence: (.+)$", log, flags=re.MULTILINE)
    if len(matches) != 1:
        raise RuntimeError("v0.1.0 fixture did not report one owned root")
    fixture = Path(matches[0]).resolve(strict=True)
    if fixture.parent != parent.resolve() or not fixture.name.startswith("arcusis-engine-probe-"):
        raise RuntimeError("v0.1.0 fixture escaped its owned temporary root")
    for phase in ("initial", "restart"):
        report = json.loads((fixture / f"{phase}.json").read_text())
        if report.get("passed") is not True or report.get("probeMode") != "full-fixture":
            raise RuntimeError(f"v0.1.0 {phase} fixture did not pass")
    return fixture


def account_url_from_session(session):
    urls = {tab["url"] for space in session["spaces"] for tab in space["tabs"]}
    accounts = set()
    for url in urls:
        parsed = urlsplit(url)
        if (parsed.scheme == "http" and parsed.hostname == "127.0.0.1"
                and parsed.port is not None and parsed.path == "/account"):
            accounts.add(url)
    if len(accounts) != 1:
        raise RuntimeError("v0.1.0 session needs one loopback account URL")
    return accounts.pop()


def stage_old_data(fixture, home):
    destination = home / "Library/Application Support/Arcusis Browser"
    destination.mkdir(parents=True)
    shutil.copy2(fixture / "session.json", destination / "session.json")
    shutil.copytree(fixture / "Chromium", destination / "Chromium")
    for account, profile in PROFILES.items():
        bookmark = destination / "Chromium" / f"Profile {profile}" / "Bookmarks"
        if f"{account.title()} console" not in bookmark.read_text():
            raise RuntimeError(f"v0.1.0 did not save the {account} bookmark")
    return destination


def encrypt_password(password, secret):
    key = hashlib.pbkdf2_hmac("sha1", secret.encode(), b"saltysalt", 1003, 16)
    command = ["openssl", "enc", "-aes-128-cbc", "-nosalt", "-K", key.hex(),
               "-iv", (b" " * 16).hex()]
    result = subprocess.run(command, input=password.encode(), capture_output=True, check=True)
    return b"v10" + result.stdout


def decrypt_password(blob, secret):
    if not blob.startswith(b"v10"):
        raise RuntimeError("Password fixture lost its Chromium v10 prefix")
    key = hashlib.pbkdf2_hmac("sha1", secret.encode(), b"saltysalt", 1003, 16)
    command = ["openssl", "enc", "-d", "-aes-128-cbc", "-nosalt", "-K", key.hex(),
               "-iv", (b" " * 16).hex()]
    result = subprocess.run(command, input=blob[3:], capture_output=True, check=True)
    return result.stdout.decode()


def add_password_fixtures(data_root, fixture_url, secret):
    passwords = {}
    for account, profile in PROFILES.items():
        database = data_root / "Chromium" / f"Profile {profile}" / "Login Data"
        password = f"{account}-upgrade-password-{uuid.uuid4()}"
        with sqlite3.connect(database) as connection:
            columns = {row[1] for row in connection.execute("pragma table_info(logins)")}
            required = {"origin_url", "signon_realm", "date_created", "blacklisted_by_user",
                        "scheme", "username_value", "password_value"}
            if not required <= columns:
                raise RuntimeError("v0.1.0 Login Data schema changed")
            connection.execute(
                "INSERT INTO logins (origin_url, signon_realm, date_created, "
                "blacklisted_by_user, scheme, username_value, password_value) "
                "VALUES (?, ?, ?, 0, 0, ?, ?)",
                (fixture_url, fixture_url, 1, f"{account}-upgrade-user",
                 encrypt_password(password, secret)))
        passwords[account] = password
    return passwords


def verify_password_fixtures(data_root, migrated_secret, expected):
    for account, profile in PROFILES.items():
        database = data_root / "Chromium" / f"Profile {profile}" / "Login Data"
        with sqlite3.connect(database) as connection:
            rows = connection.execute("SELECT password_value FROM logins WHERE username_value=?",
                                      (f"{account}-upgrade-user",)).fetchall()
        if len(rows) != 1 or decrypt_password(rows[0][0], migrated_secret) != expected[account]:
            raise RuntimeError(f"{account} encrypted password did not survive upgrade")


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"<!doctype html><html><title>Account fixture</title><body>Account</body></html>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *arguments):
        pass


def run_upgrade_probe(app, fixture, home, data_root, environment, expected_passwords, keychain,
                      legacy_secret, log):
    session = json.loads((fixture / "session.json").read_text())
    fixture_url = account_url_from_session(session)
    port = urlsplit(fixture_url).port
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Fixture)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        output = fixture / "upgrade.json"
        arguments = [str(app / "Contents/MacOS/ShaarVerification"), "--probe-upgrade",
                     "--probe-data-dir", str(fixture), "--probe-home", str(home),
                     "--probe-output", str(output), "--probe-url", fixture_url,
                     "--probe-framework",
                     str(app / "Contents/Frameworks/Chromium Framework.framework")]
        run_checked(["nice", "-n", "19", *arguments], env=environment, timeout=120,
                    output=log)
        report = json.loads(output.read_text())
        if report.get("passed") is not True or report.get("realKeychain") is not True:
            raise RuntimeError("Shaar upgrade probe did not pass")
        migrated = keychain_secret(keychain, "Shaar Safe Storage", "Shaar", environment)
        if migrated != legacy_secret:
            raise RuntimeError("Shaar Safe Storage differs from the legacy key")
        if keychain_secret(keychain, "Ardia Safe Storage", "Ardia", environment) != legacy_secret:
            raise RuntimeError("Ardia Safe Storage changed during upgrade")
        verify_password_fixtures(data_root, migrated, expected_passwords)
        return report
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


def execute(output):
    runner_temp = require_disposable_runner(os.environ, getpass.getuser())
    if os.uname().machine != "arm64":
        raise RuntimeError("Upgrade test requires Apple silicon")
    evidence = output.parent
    evidence.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="arcusis-upgrade-", dir=runner_temp) as temporary:
        root = Path(temporary).resolve(strict=True)
        home = root / "home"
        home.mkdir(mode=0o700)
        environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home),
                           TMPDIR=str(root))
        check_isolated_home(root, environment)
        release_zip = root / "Shaar-0.1.0-macos.zip"
        release = fetch_release_zip(release_zip)
        released = root / "released"
        run_checked(["ditto", "-x", "-k", str(release_zip), str(released)])
        released_app = released / "Shaar.app"
        if plistlib.loads((released_app / "Contents/Info.plist").read_bytes()).get(
                "CFBundleIdentifier") != "com.arcusis.browser":
            raise RuntimeError("Released v0.1.0 bundle identifier changed")
        framework = released_app / "Contents/Frameworks/Chromium Framework.framework"
        if not framework.is_dir():
            raise RuntimeError("Released v0.1.0 Ardia framework missing")
        old_source = root / "v010-source"
        extract_old_source(old_source, release)
        prepare_old_harness(old_source, framework)
        with throwaway_keychain(root, environment) as (keychain, legacy_secret):
            run_checked(["nice", "-n", "19", "bash", "scripts/bundle-app.sh",
                         "--with-engine", "--verification"], cwd=old_source,
                        env=environment, timeout=900, output=evidence / "old-bundle.log")
            old_app = old_source / "build/Shaar Verification.app"
            set_shipping_bundle_id(old_app)
            old_log = run_checked(["nice", "-n", "19", "python3", "scripts/engine_fixture.py"],
                                  cwd=old_source, env=environment, timeout=900,
                                  output=evidence / "old-fixture.log")
            fixture = fixture_root_from_log(old_log, root)
            data_root = stage_old_data(fixture, home)
            session = json.loads((fixture / "session.json").read_text())
            fixture_url = account_url_from_session(session)
            passwords = add_password_fixtures(data_root, fixture_url, legacy_secret)
            run_checked(["nice", "-n", "19", "bash", "scripts/bundle-app.sh",
                         "--with-engine", "--verification"], cwd=ROOT,
                        env=dict(environment, SHAAR_BUNDLE_SWIFT_JOBS="4"),
                        timeout=900, output=evidence / "shaar-bundle.log")
            shaar_app = ROOT / "build/Shaar Verification.app"
            shaar_copy = root / "Shaar Upgrade Verification.app"
            run_checked(["ditto", str(shaar_app), str(shaar_copy)])
            set_shipping_bundle_id(shaar_copy)
            report = run_upgrade_probe(shaar_copy, fixture, home, data_root, environment,
                                       passwords, keychain, legacy_secret,
                                       evidence / "upgrade.log")
        summary = {"schemaVersion": 1, "passed": True, "oldRelease": release["tag"],
                   "newRelease": json.loads((ROOT / "ThirdParty/ChromiumEngine/pin.json").read_text())["releaseTag"],
                   "sameBundleIdentifier": "com.arcusis.browser", "temporaryHome": True,
                   "throwawayKeychain": True, "realKeychain": True,
                   "oldHarness": "v0.1.0 source plus hidden guard, real keychain, native bookmark fixture",
                   "oldPhases": 2, "checks": report["checks"],
                   "encryptedPasswords": sorted(passwords), "safeStorageKeyMigrated": True}
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    print(f"Upgrade PASS; redacted evidence: {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/ci/upgrade-v010/summary.json")
    options = parser.parse_args()
    try:
        execute(options.output)
    except Exception as error:
        options.output.parent.mkdir(parents=True, exist_ok=True)
        options.output.write_text(json.dumps({"schemaVersion": 1, "passed": False,
                                             "error": str(error)}, sort_keys=True) + "\n")
        raise


if __name__ == "__main__":
    main()
