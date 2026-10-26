#!/usr/bin/env python3
"""Opt-in synthetic SDK backend integration against an owned loopback fixture."""
from __future__ import annotations

import argparse
import base64
import hashlib
import http.server
import importlib.util
import json
import os
import re
import signal
import socket
import socketserver
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "build/NativeBitwardenOrganizationSDK/Package"
ORG = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
OTHER = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
REVIEW = ROOT / "build/OrganizationBackendProbeCleanup"
PREBUILT = ROOT / "build/OrganizationBackendProbeReview"
BUNDLE = PREBUILT / "swiftpm-candidate/out/Products/Debug/BrowserAppTests.xctest"
BUILD_STAMP = PREBUILT / "candidate-build-inputs.json"
SANDBOX = "/usr/bin/sandbox-exec"
POLICY = "(version 1) (allow default) (deny process-fork)"
PINS = {
    "manifest": "10549e08f2e6f056f5ba74237e9ec08d2d6e26208bacb049b0e54734d06e04a4",
    "fixture": "2347b7c7b3856b4672c38354fcaa00b0a2bb8afdbf842145230328bb6b9fb2c7",
    "helper": "3ca09aaa9606366702980f40ab838f412d04ab5489f9d5d9f97242a8fbda7bc5",
    "extractor": "ed4436414633d5d89be69d7ef89f241e775f13b5a5b9c6ad167884ea05d807bb",
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def child_environment():
    return {"PATH": "/usr/bin:/bin", "HOME": str(Path.home()),
            "TMPDIR": os.environ.get("TMPDIR", "/tmp")}


def verify_inputs(source, helper):
    manifest_path = PACKAGE / "build-manifest.json"
    fixture_path = source / "crates/bitwarden-core/src/client/test_accounts.rs"
    if (digest(manifest_path) != PINS["manifest"] or digest(fixture_path) != PINS["fixture"]
            or digest(helper) != PINS["helper"]
            or digest(ROOT / "scripts/test-native-bitwarden-sync.py") != PINS["extractor"]):
        raise RuntimeError("input pin mismatch")
    manifest = json.loads(manifest_path.read_text())
    for name, expected in manifest["fileSHA256"].items():
        path = PACKAGE / name
        if digest(path) != expected:
            raise RuntimeError("package pin mismatch")


def verify_prebuilt():
    paths = [ROOT / "Sources/ArcusisBrowser/NativeBitwardenBackend.swift",
             ROOT / "Tests/BrowserAppTests/NativeBitwardenOrganizationBackendTests.swift",
             BUNDLE / "Contents/MacOS/BrowserAppTests"]
    if json.loads(BUILD_STAMP.read_text()) != {str(path): digest(path) for path in paths}:
        raise RuntimeError("prebuilt input mismatch")


def sandbox_command(command):
    return [SANDBOX, "-p", POLICY, *command]


def stop_child(child):
    if child is None:
        return True
    for sig in (signal.SIGTERM, signal.SIGKILL):
        if child.poll() is not None:
            return True
        try:
            if os.getpgid(child.pid) != child.pid:
                return False
            os.kill(child.pid, sig)
        except ProcessLookupError:
            pass
        try:
            child.wait(timeout=3)
            return True
        except subprocess.TimeoutExpired:
            continue
    return child.poll() is not None


def sandboxed_output(command, *, data=None, timeout=30):
    child = subprocess.Popen(sandbox_command(command), stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             start_new_session=True, env=child_environment())
    try:
        output, _ = child.communicate(input=data, timeout=timeout)
        if child.returncode != 0:
            raise RuntimeError("sandboxed child failed")
        return output
    finally:
        if not stop_child(child):
            raise RuntimeError("sandboxed child cleanup failed")


def verify_sandbox():
    # Both mechanisms must fail with EPERM under the exact policy used below.
    control = '''import errno, os
try:
    pid = os.fork()
except OSError as error:
    if error.errno != errno.EPERM: raise
else:
    if pid == 0: os._exit(0)
    os.waitpid(pid, 0)
    raise SystemExit(1)
try:
    pid = os.posix_spawn("/usr/bin/true", ["true"], {"PATH": "/usr/bin:/bin"})
except OSError as error:
    if error.errno != errno.EPERM: raise
else:
    os.waitpid(pid, 0)
    raise SystemExit(1)
print("spawn_denied")
'''
    if sandboxed_output([sys.executable, "-c", control], timeout=10) != b"spawn_denied\n":
        raise RuntimeError("sandbox control failed")
    path = sandboxed_output(["/usr/bin/xcrun", "--find", "xctest"], timeout=10).decode().strip()
    if path != "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest" or not Path(path).is_file():
        raise RuntimeError("unexpected xctest path")
    return path


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass

    def setup(self):
        super().setup()
        self.connection.settimeout(3)

    def reply(self, status, value):
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        try:
            if self.client_address[0] != "127.0.0.1" or self.headers.get("Transfer-Encoding"):
                self.reply(400, {})
                return
            length = int(self.headers.get("Content-Length", "-1"))
            if not 0 <= length <= 65536:
                self.reply(400, {})
                return
            body = self.rfile.read(length)
            if self.path == "/control":
                value = json.loads(body)
                if "cipher" in value:
                    self.server.cipher = value["cipher"]
                self.server.mode = value["mode"]
                self.reply(200, {})
            elif self.path == "/identity/accounts/prelogin/password":
                self.server.counts["prelogin"] += 1
                if json.loads(body).get("email") != self.server.fixture["email"]:
                    self.reply(400, {})
                    return
                self.reply(200, {"kdfSettings": {"kdfType": 0, "iterations": self.server.fixture["iterations"]}, "salt": self.server.fixture["email"]})
            elif self.path == "/identity/connect/token":
                self.server.counts["login"] += 1
                self.reply(200, self.server.login_response)
            else:
                self.reply(404, {})
        except (OSError, ValueError, KeyError, TypeError):
            try:
                self.reply(400, {})
            except OSError:
                pass

    def do_GET(self):
        if self.client_address[0] != "127.0.0.1" or not self.path.startswith("/api/sync"):
            self.reply(404, {})
            return
        self.server.counts["sync"] += 1
        if self.headers.get("Authorization") != "Bearer " + self.server.login_response["access_token"]:
            self.reply(401, {})
            return
        mode = self.server.mode
        if mode == "failed":
            self.reply(401, {})
            return
        if mode == "malformed":
            self.reply(200, {"profile": "invalid"})
            return
        orgs = [] if mode in ("empty", "missing") else [{"id": OTHER if mode == "unrelated" else ORG, "key": self.server.key}]
        profile = {"id": self.server.fixture["userID"], "email": self.server.fixture["email"],
                   "emailVerified": True, "organizationsNew": orgs}
        self.reply(200, {"profile": profile, "folders": [],
                         "ciphers": [] if mode == "empty" else [self.server.cipher],
                         "sends": [], "policiesNew": [], "userDecryption": {}})


class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(self, *args):
        self.active = {}
        self.request_threads = []
        self.active_lock = threading.Lock()
        super().__init__(*args)

    def process_request(self, request, client_address):
        thread = threading.Thread(target=self.process_request_thread, args=(request, client_address), daemon=True)
        with self.active_lock:
            self.active[request] = thread
            self.request_threads.append(thread)
        try:
            thread.start()
        except BaseException:
            with self.active_lock:
                self.active.pop(request, None)
                self.request_threads.remove(thread)
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            with self.active_lock:
                self.active.pop(request, None)

    def handle_error(self, *_args):
        pass


def stop_listener(server, thread, stop_server):
    stop_server.set()
    thread.join(timeout=3)
    server.server_close()
    if thread.is_alive():
        thread.join(timeout=3)
    return not thread.is_alive() and server.socket.fileno() == -1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--source", type=Path)
    parser.add_argument("--helper", type=Path)
    args = parser.parse_args()
    if not args.run:
        print("organization_backend=skipped reason=opt_in_required")
        return 0
    if (not (PACKAGE / "Package.swift").is_file() or args.source is None or args.helper is None
            or not args.source.is_dir() or not args.helper.is_file()):
        print("organization_backend=failed reason=fixture_or_candidate_unavailable")
        return 1
    verify_inputs(args.source, args.helper)
    verify_prebuilt()
    xctest = verify_sandbox()
    spec = importlib.util.spec_from_file_location("sync_fixture", ROOT / "scripts/test-native-bitwarden-sync.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    fixture = module.sdk_vector(args.source)
    source = (args.source / "crates/bitwarden-core/src/client/test_accounts.rs").read_text()
    sql = source.split("INSERT INTO vault_dev.dbo.[User]", 1)[1].split("INSERT INTO vault_dev.dbo.Organization", 1)[0]
    match = re.search(r"N\s*'(MIIBIjAN[^']+)'", sql)
    if not match:
        raise RuntimeError("public fixture unavailable")
    key = sandboxed_output([str(args.helper)], data=match.group(1).encode()).decode()
    claims = base64.urlsafe_b64encode(json.dumps({"sub": fixture["userID"]}).encode()).decode().rstrip("=")
    token = "e30." + claims + ".c2ln"
    login_response = {
        "access_token": token, "expires_in": 3600, "token_type": "Bearer", "refresh_token": "synthetic-refresh",
        "scope": "api offline_access", "PrivateKey": fixture["privateKey"],
        "AccountKeys": {"publicKeyEncryptionKeyPair": {"wrappedPrivateKey": fixture["privateKey"],
                        "publicKey": match.group(1), "Object": "publicKeyEncryptionKeyPair"}, "Object": "privateKeys"},
        "Key": fixture["wrappedUserKey"], "MasterPasswordPolicy": {"Object": "masterPasswordPolicy"},
        "ForcePasswordReset": False, "Kdf": 0, "KdfIterations": fixture["iterations"],
        "KdfMemory": None, "KdfParallelism": None,
        "UserDecryptionOptions": {"HasMasterPassword": True,
            "MasterPasswordUnlock": {"Kdf": {"KdfType": 0, "Iterations": fixture["iterations"]},
                "MasterKeyEncryptedUserKey": fixture["wrappedUserKey"], "Salt": fixture["email"]},
            "Object": "userDecryptionOptions"}}
    server = Server(("127.0.0.1", 0), Handler)
    server.fixture, server.key, server.login_response = fixture, key, login_response
    server.mode, server.cipher, server.counts = "success", None, {"prelogin": 0, "login": 0, "sync": 0}
    address = server.server_address
    server.timeout = 0.1
    stop_server = threading.Event()
    def serve():
        while not stop_server.is_set():
            server.handle_request()
    thread = threading.Thread(target=serve, daemon=True)
    try:
        thread.start()
    except BaseException:
        server.server_close()
        raise
    child = None
    try:
        fixture.update(org=ORG, key=key, endpoint=f"http://127.0.0.1:{address[1]}")
        env = dict(child_environment(), ARCUSIS_ORG_BACKEND_TEST="1",
                   ARCUSIS_ORG_BACKEND_FIXTURE=base64.b64encode(json.dumps(fixture).encode()).decode())
        command = [xctest, "-XCTest",
                   "BrowserAppTests.NativeBitwardenOrganizationBackendTests/testSyntheticOrganizationBackend",
                   str(BUNDLE)]
        child = subprocess.Popen(sandbox_command(command), cwd=ROOT, env=env, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        REVIEW.mkdir(parents=True, exist_ok=True)
        (REVIEW / "owned-resources.json").write_text(json.dumps({"child_pid": child.pid, "port": address[1]}))
        try:
            output, _ = child.communicate(timeout=600)
        except subprocess.TimeoutExpired:
            (REVIEW / "test-evidence.txt").write_text("test_timeout=true\n")
            raise RuntimeError("test timeout") from None
        # Retain only test-run markers and counts; compiler output may contain fixture data.
        markers = [line for line in output.decode(errors="replace").splitlines()
                   if re.fullmatch(r"\s*Executed \d+ tests?, with \d+ failures? \(\d+ unexpected\) in [0-9.]+ \([0-9.]+\) seconds", line)]
        (REVIEW / "test-evidence.txt").write_text(
            "returncode=" + str(child.returncode) + "\n" + "\n".join(markers) + "\n")
        verify_inputs(args.source, args.helper)
        verify_prebuilt()
        passed = (child.returncode == 0 and b"Executed 1 test, with 0 failures" in output
                  and server.counts == {"prelogin": 2, "login": 2, "sync": 11})
        print("organization_backend_execution=" + ("passed" if passed else "failed"))
        print("requests=" + json.dumps(server.counts, sort_keys=True))
        return 0 if passed else 1
    finally:
        child_gone = stop_child(child)
        listener_gone = stop_listener(server, thread, stop_server)
        with server.active_lock:
            active = list(server.active)
        for request in active:
            try:
                request.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            request.close()
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            with server.active_lock:
                if not server.active:
                    break
            time.sleep(0.1)
        with server.active_lock:
            threads = list(server.request_threads)
        for request_thread in threads:
            request_thread.join(timeout=max(0, deadline - time.monotonic()))
        with server.active_lock:
            requests_gone = not server.active and all(not item.is_alive() for item in threads)
        with socket.socket() as probe:
            probe.settimeout(0.5)
            closed = probe.connect_ex(address) != 0
        cleanup = child_gone and requests_gone and listener_gone and closed
        print("owned_cleanup=" + ("passed" if cleanup else "failed"))
        if not cleanup:
            raise RuntimeError("owned listener or child cleanup failed")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        print("organization_backend=failed reason=fixture_or_runner_failure", file=sys.stderr)
        raise SystemExit(1)
