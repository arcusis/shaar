#!/usr/bin/env python3
"""Opt-in, owned loopback host proof against the separate debug SDK7 fixture."""
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
from urllib.parse import parse_qs

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "build/NativeBitwardenRefreshSDK7Fixture/Package"
SCRATCH = ROOT / "build/NativeRefreshFinalGaps/fixture"
BUNDLE = SCRATCH / "out/Products/Debug/BrowserAppTests.xctest"
BINARY = BUNDLE / "Contents/MacOS/BrowserAppTests"
STAMP = ROOT / "build/NativeRefreshFinalGaps/fixture-build-inputs.json"
SOURCE = ROOT / "build/SDKCache/bitwarden-sdk-5cf9198"
VECTOR_HASH = "2347b7c7b3856b4672c38354fcaa00b0a2bb8afdbf842145230328bb6b9fb2c7"
EXTRACTOR_HASH = "ed4436414633d5d89be69d7ef89f241e775f13b5a5b9c6ad167884ea05d807bb"
VECTOR_RUNNER = ROOT / "scripts/test-native-bitwarden-sync.py"
XCTEST = Path("/Applications/Xcode.app/Contents/Developer/usr/bin/xctest")
SANDBOX = "/usr/bin/sandbox-exec"
POLICY = "(version 1) (allow default) (deny process-fork)"


def digest(path: Path) -> str:
    if path.is_symlink() or not path.is_file():
        raise RuntimeError("invalid input file")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def clean_environment() -> dict[str, str]:
    return {key: os.environ[key] for key in ("PATH", "HOME", "TMPDIR") if key in os.environ}


def package_manifest(expected: str) -> str:
    manifest_path = PACKAGE / "fixture-manifest.json"
    actual = digest(manifest_path)
    if actual != expected:
        raise RuntimeError("fixture manifest hash mismatch")
    manifest = json.loads(manifest_path.read_text())
    if (manifest.get("accepted") is not False or manifest.get("integration_ready") is not False
            or manifest.get("testOnly") is not True or manifest.get("profile") != "debug"
            or manifest.get("architecture") != "arm64" or manifest.get("minMacOS") != "26.0"
            or manifest.get("sourceCommit") != "5cf919837e83b71c2508bf99344ea57cf5f84e88"):
        raise RuntimeError("fixture package status or source mismatch")
    inventory = manifest.get("fileSHA256")
    if not isinstance(inventory, dict) or not inventory:
        raise RuntimeError("fixture inventory missing")
    files = set()
    for path in PACKAGE.rglob("*"):
        if path.is_symlink():
            raise RuntimeError("fixture symlink rejected")
        if path.is_file() and path != manifest_path:
            files.add(path.relative_to(PACKAGE).as_posix())
    if files != set(inventory):
        raise RuntimeError("fixture inventory is incomplete")
    for name, value in inventory.items():
        path = PACKAGE / name
        if path.resolve().is_relative_to(PACKAGE.resolve()) is False or digest(path) != value:
            raise RuntimeError("fixture inventory mismatch")
    return actual


def source_hashes() -> dict[str, str]:
    paths = [ROOT / "Package.swift"]
    for directory in (ROOT / "Sources", ROOT / "Tests"):
        for path in directory.rglob("*"):
            if path.is_symlink():
                raise RuntimeError("source symlink rejected")
            if path.is_file():
                paths.append(path)
    return {str(path.relative_to(ROOT)): digest(path) for path in sorted(paths)}


def input_fingerprints(manifest: str) -> dict[str, object]:
    return {"manifest": package_manifest(manifest), "sources": source_hashes(),
            "runner": digest(Path(__file__))}


def process_group_exists(pgid: int) -> bool:
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def terminate_owned_group(process: subprocess.Popen[bytes], grace: float = 3.0) -> None:
    pgid = process.pid
    if process.poll() is None and os.getpgid(pgid) != pgid:
        raise RuntimeError("owned process identity changed")
    if process_group_exists(pgid):
        try:
            os.killpg(pgid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        pass
    if process_group_exists(pgid):
        try:
            os.killpg(pgid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=grace)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError("owned process did not exit") from error
    deadline = time.monotonic() + grace
    while process_group_exists(pgid) and time.monotonic() < deadline:
        time.sleep(0.05)
    if process_group_exists(pgid):
        raise RuntimeError("owned process group did not exit")


def run_owned_build(command: list[str], environment: dict[str, str], timeout: float = 600) -> None:
    process = subprocess.Popen(command, cwd=ROOT, env=environment, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True)
    try:
        try:
            process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired as error:
            raise RuntimeError("fixture test build timed out; owned group exited") from error
        if process.returncode != 0:
            raise RuntimeError("fixture test build failed")
        if process_group_exists(process.pid):
            raise RuntimeError("fixture build left owned descendants")
    except BaseException:
        terminate_owned_group(process)
        raise
    finally:
        if process.stdout is not None:
            process.stdout.close()
        if process.stderr is not None:
            process.stderr.close()


def build(manifest: str) -> None:
    STAMP.unlink(missing_ok=True)
    before = input_fingerprints(manifest)
    environment = clean_environment()
    environment["ARCUSIS_NATIVE_BITWARDEN_REFRESH_FIXTURE"] = "1"
    command = ["swift", "build", "--build-tests", "--jobs", "2", "--scratch-path", str(SCRATCH)]
    run_owned_build(command, environment)
    after = input_fingerprints(manifest)
    if before != after:
        raise RuntimeError("fixture build inputs changed during build")
    STAMP.parent.mkdir(parents=True, exist_ok=True)
    STAMP.write_text(json.dumps(after | {"test_binary": digest(BINARY)}, sort_keys=True))
    print("fixture_build=passed")


def validate_prebuilt(manifest: str) -> None:
    actual = input_fingerprints(manifest) | {"test_binary": digest(BINARY)}
    if json.loads(STAMP.read_text()) != actual:
        raise RuntimeError("fixture build inputs changed")
    if not XCTEST.is_file():
        raise RuntimeError("xctest unavailable")


def verify_sandbox() -> None:
    control = r'''import errno, os
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
    result = subprocess.run(
        [SANDBOX, "-p", POLICY, sys.executable, "-c", control], env=clean_environment(),
        capture_output=True, timeout=10)
    if result.returncode != 0 or result.stdout != b"spawn_denied\n":
        raise RuntimeError("sandbox control failed")


def public_vector() -> tuple[dict[str, object], str]:
    source = SOURCE / "crates/bitwarden-core/src/client/test_accounts.rs"
    if digest(source) != VECTOR_HASH or digest(VECTOR_RUNNER) != EXTRACTOR_HASH:
        raise RuntimeError("public fixture or extractor hash mismatch")
    spec = importlib.util.spec_from_file_location("owned_vector", VECTOR_RUNNER)
    if spec is None or spec.loader is None:
        raise RuntimeError("fixture extractor unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    vector = module.sdk_vector(SOURCE)
    text = source.read_text()
    section = text.split("INSERT INTO vault_dev.dbo.[User]", 1)[1].split(
        "INSERT INTO vault_dev.dbo.Organization", 1)[0]
    match = re.search(r"N\s*'(MIIBIjAN[^']+)'", section)
    if not match:
        raise RuntimeError("public key fixture unavailable")
    return vector, match.group(1)


def token(user_id: str, expires: int, nonce: str) -> str:
    payload = json.dumps({"sub": user_id, "client_id": "desktop", "exp": expires,
                          "jti": nonce, "scope": ["api"]}).encode()
    return "e30." + base64.urlsafe_b64encode(payload).decode().rstrip("=") + ".c2ln"


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args: object) -> None:
        pass

    def setup(self) -> None:
        super().setup()
        self.connection.settimeout(3)

    def reply(self, status: int, value: dict[str, object]) -> None:
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:
        try:
            if self.client_address[0] != "127.0.0.1" or self.headers.get("Transfer-Encoding"):
                self.reply(400, {})
                return
            length = int(self.headers.get("Content-Length", "-1"))
            if not 0 <= length <= 65536:
                self.reply(400, {})
                return
            body = self.rfile.read(length)
            if self.path == "/identity/accounts/prelogin/password":
                if json.loads(body).get("email") != self.server.vector["email"]:
                    self.reply(400, {})
                    return
                self.server.counts["prelogin"] += 1
                self.reply(200, {"kdfSettings": {"kdfType": 0,
                          "iterations": self.server.vector["iterations"]},
                          "salt": self.server.vector["email"]})
            elif self.path == "/identity/connect/token":
                form = parse_qs(body.decode(), keep_blank_values=True)
                grant = form.get("grant_type", [""])[0]
                if form.get("client_id") != ["desktop"]:
                    self.reply(400, {})
                elif grant == "refresh_token":
                    if form.get("refresh_token") != [self.server.refresh_token]:
                        self.reply(400, {})
                        return
                    self.server.counts["refresh"] += 1
                    if self.server.counts["refresh"] > 2:
                        self.reply(400, {})
                        return
                    self.server.refresh_token = (
                        "synthetic-rotated-one" if self.server.counts["refresh"] == 1
                        else "synthetic-rotated-two")
                    self.server.access_token = self.server.refreshed_tokens[self.server.counts["refresh"] - 1]
                    self.reply(200, {"access_token": self.server.access_token,
                               "expires_in": 3600, "refresh_token": self.server.refresh_token,
                               "token_type": "Bearer", "scope": "api offline_access"})
                elif grant == "password":
                    self.server.counts["login"] += 1
                    self.reply(200, self.server.login_response)
                else:
                    self.reply(400, {})
            else:
                self.reply(404, {})
        except (OSError, ValueError, KeyError, TypeError):
            try:
                self.reply(400, {})
            except OSError:
                pass

    def do_GET(self) -> None:
        if self.client_address[0] != "127.0.0.1" or not self.path.startswith("/api/sync"):
            self.reply(404, {})
            return
        self.server.counts["sync"] += 1
        if self.headers.get("Authorization") != "Bearer " + self.server.access_token:
            self.reply(401, {})
            return
        if self.server.counts["sync"] == 1:
            self.reply(401, {})
            return
        if self.server.counts["sync"] == 3:
            self.reply(403, {})
            return
        profile = {"id": self.server.vector["userID"], "email": self.server.vector["email"],
                   "emailVerified": True, "organizationsNew": []}
        self.reply(200, {"profile": profile, "folders": [], "ciphers": [], "sends": [],
                         "policiesNew": [], "userDecryption": {}})


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = False
    daemon_threads = True

    def __init__(self, address: tuple[str, int]):
        super().__init__(address, Handler)
        self.active: set[socket.socket] = set()
        self.threads: list[threading.Thread] = []
        self.lock = threading.Lock()

    def process_request(self, request: socket.socket, address: tuple[str, int]) -> None:
        thread = threading.Thread(target=self.process_request_thread, args=(request, address), daemon=True)
        with self.lock:
            self.active.add(request)
            self.threads.append(thread)
        try:
            thread.start()
        except BaseException:
            with self.lock:
                self.active.discard(request)
                self.threads.remove(thread)
            raise

    def process_request_thread(self, request: socket.socket, address: tuple[str, int]) -> None:
        try:
            super().process_request_thread(request, address)
        finally:
            with self.lock:
                self.active.discard(request)

    def handle_error(self, *_args: object) -> None:
        pass


def run(manifest: str) -> None:
    validate_prebuilt(manifest)
    verify_sandbox()
    for method in ("testFixtureGuardRejectsDesktopExecutable", "testFixtureGuardAcceptsCurrentTestHost"):
        guard_command = [SANDBOX, "-p", POLICY, str(XCTEST), "-XCTest",
                         "BrowserAppTests.NativeBitwardenRefreshHostFixtureTests/" + method,
                         str(BUNDLE)]
        guard_result = subprocess.run(
            guard_command, cwd=ROOT, env=clean_environment(), capture_output=True, timeout=30)
        if (guard_result.returncode != 0 or
                b"Executed 1 test, with 0 failures" not in (guard_result.stdout + guard_result.stderr)):
            raise RuntimeError("fixture host guard failed")
    vector, public_key = public_vector()
    now = int(time.time())
    initial = token(str(vector["userID"]), now + 30, "initial")
    refreshed = [token(str(vector["userID"]), now + 3600, "rotation-one"),
                 token(str(vector["userID"]), now + 3600, "rotation-two")]
    login = {
        "access_token": initial, "expires_in": 30, "token_type": "Bearer",
        "refresh_token": "synthetic-initial", "scope": "api offline_access",
        "PrivateKey": vector["privateKey"],
        "AccountKeys": {"publicKeyEncryptionKeyPair": {"wrappedPrivateKey": vector["privateKey"],
                        "publicKey": public_key, "Object": "publicKeyEncryptionKeyPair"},
                        "Object": "privateKeys"},
        "Key": vector["wrappedUserKey"], "MasterPasswordPolicy": {"Object": "masterPasswordPolicy"},
        "ForcePasswordReset": False, "Kdf": 0, "KdfIterations": vector["iterations"],
        "KdfMemory": None, "KdfParallelism": None,
        "UserDecryptionOptions": {"HasMasterPassword": True,
            "MasterPasswordUnlock": {"Kdf": {"KdfType": 0, "Iterations": vector["iterations"]},
                "MasterKeyEncryptedUserKey": vector["wrappedUserKey"], "Salt": vector["email"]},
            "Object": "userDecryptionOptions"},
    }
    server = Server(("127.0.0.1", 0))
    server.vector, server.refreshed_tokens, server.login_response = vector, refreshed, login
    server.access_token, server.refresh_token = initial, "synthetic-initial"
    server.counts = {"prelogin": 0, "login": 0, "refresh": 0, "sync": 0}
    address = server.server_address
    server.timeout = 0.1
    stop = threading.Event()
    def serve() -> None:
        while not stop.is_set():
            server.handle_request()
    thread = threading.Thread(target=serve, daemon=True)
    child = None
    started = False
    try:
        thread.start()
        started = True
        payload = {"endpoint": f"http://127.0.0.1:{address[1]}",
                   "email": vector["email"], "userID": vector["userID"],
                   "currentPassword": vector["currentPassword"]}
        environment = clean_environment()
        environment["ARCUSIS_REFRESH_HOST_FIXTURE"] = base64.b64encode(json.dumps(payload).encode()).decode()
        command = [SANDBOX, "-p", POLICY, str(XCTEST), "-XCTest",
                   "BrowserAppTests.NativeBitwardenRefreshHostFixtureTests/testOwnedHostRefreshAndLockedRestart",
                   str(BUNDLE)]
        child = subprocess.Popen(command, cwd=ROOT, env=environment, stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, start_new_session=True)
        output, _ = child.communicate(timeout=90)
        markers = [line for line in output.decode(errors="replace").splitlines()
                   if re.fullmatch(r"\s*Executed 1 test, with 0 failures? \(0 unexpected\) in [0-9.]+ \([0-9.]+\) seconds", line)]
        expected = {"prelogin": 1, "login": 1, "refresh": 2, "sync": 3}
        if child.returncode != 0 or not markers or server.counts != expected:
            print("fixture_request_counts=" + json.dumps(server.counts, sort_keys=True))
            raise RuntimeError("host fixture assertions failed")
        validate_prebuilt(manifest)
        print("fixture_guard=passed")
        print("host_fixture=passed")
        print("requests=" + json.dumps(server.counts, sort_keys=True))
    finally:
        if child is not None and child.poll() is None:
            if os.getpgid(child.pid) != child.pid:
                raise RuntimeError("owned child identity changed")
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait(timeout=3)
        stop.set()
        if started:
            thread.join(timeout=3)
        server.server_close()
        with server.lock:
            active, threads = list(server.active), list(server.threads)
        for connection in active:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            connection.close()
        for request_thread in threads:
            request_thread.join(timeout=3)
        with socket.socket() as probe:
            probe.settimeout(0.5)
            closed = probe.connect_ex(address) != 0
        if thread.is_alive() or any(t.is_alive() for t in threads) or not closed:
            raise RuntimeError("owned resource cleanup failed")
        print("owned_cleanup=passed")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest-sha256", required=True)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--build", action="store_true")
    mode.add_argument("--run", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{64}", args.manifest_sha256):
        raise RuntimeError("invalid manifest hash")
    manifest = package_manifest(args.manifest_sha256)
    if args.build:
        build(manifest)
    else:
        run(manifest)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, IndexError, TypeError, RuntimeError, subprocess.SubprocessError):
        print("host_fixture=failed", file=sys.stderr)
        raise SystemExit(1)
