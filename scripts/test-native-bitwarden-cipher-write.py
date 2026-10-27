#!/usr/bin/env python3
"""Run one owned SDK7 cipher-write fixture against a loopback-only service."""

from __future__ import annotations

import argparse
import base64
import hashlib
import http.server
import importlib.util
import json
import os
import re
import shutil
import signal
import socket
import socketserver
import subprocess
import sys
import threading
import tempfile
import time
from pathlib import Path
from unittest.mock import patch
from urllib.parse import parse_qs

ROOT = Path(__file__).resolve().parents[1]
# Defaults are checkout-relative; explicit inputs must be absolute and pinned.
SDK_SOURCE = ROOT / "build/NativeBitwardenRefreshSDK7Fixture/Package"
SOURCE = ROOT / "build/SDKCache/bitwarden-sdk-5cf9198"
EXTRACTOR = ROOT / "scripts/test-native-bitwarden-sync.py"
OUTPUT: Path
HARNESS: Path
SDK_COPY: Path
MANIFEST_SHA = "eb223e86bea215843191ccb01f94ff290e629f98063de0336ee51d3d9249b039"
VECTOR_SHA = "2347b7c7b3856b4672c38354fcaa00b0a2bb8afdbf842145230328bb6b9fb2c7"
EXTRACTOR_SHA = "ed4436414633d5d89be69d7ef89f241e775f13b5a5b9c6ad167884ea05d807bb"
XCTEST = Path("/Applications/Xcode.app/Contents/Developer/usr/bin/xctest")
SANDBOX = "/usr/bin/sandbox-exec"
POLICY = "(version 1) (allow default) (deny process-fork)"
CIPHER_ID = "00000000-0000-4000-8000-000000000103"
CREATED_ID = "00000000-0000-4000-8000-000000000104"
INPUTS = [
    "Sources/BrowserCore/PasswordFillBinding.swift",
    "Sources/BrowserCore/PasswordURIMatching.swift",
    "Sources/BrowserCore/PasswordAuthenticationGate.swift",
    "Sources/BrowserCore/PasswordCredentialStore.swift",
    "Sources/BrowserCore/PasswordCredentialSessionLock.swift",
    "Sources/BrowserCore/PasswordSessionRecoveryRecord.swift",
    "Sources/BrowserCore/BitwardenServerConfiguration.swift",
    "Sources/BrowserCore/Resources/public_suffix_list.dat",
    "Sources/ArcusisBrowser/NativeBitwardenBackend.swift",
    "Sources/ArcusisBrowser/NativeBitwardenWrites.swift",
    "Sources/ArcusisBrowser/NativeBitwardenCipherRepository.swift",
    "Sources/ArcusisBrowser/NativeBitwardenFillCredential.swift",
    "Sources/ArcusisBrowser/NativeBitwardenVaultSnapshot.swift",
    "Sources/ArcusisBrowser/NativeBitwardenLogging.swift",
    "Sources/ArcusisBrowser/NativeBitwardenRefreshCoordinator.swift",
    "Tests/BrowserAppTests/NativeBitwardenCipherWriteTests.swift",
    "Tests/BrowserAppTests/NativeBitwardenWriteTests.swift",
    "Tests/BrowserAppTests/NativeBitwardenCipherRepositoryTests.swift",
]
AUDIT_INPUTS = [
    "crates/bitwarden-uniffi/src/vault/ciphers.rs",
    "crates/bitwarden-vault/src/cipher/cipher_client/create.rs",
    "crates/bitwarden-vault/src/cipher/cipher_client/edit.rs",
    "crates/bitwarden-vault/src/cipher/cipher_client/mod.rs",
    "crates/bitwarden-vault/src/cipher/cipher.rs",
    "crates/bitwarden-api-api/src/models/cipher_request_model.rs",
    "crates/bitwarden-api-api/src/models/cipher_response_model.rs",
    "crates/bitwarden-core/src/client/test_accounts.rs",
]
AUDIT_SHA = [
    "f907522173dcbb3c9ac037a78142179ade435551c6c1c32e61d68f1d58cb28f5",
    "997f3a0170ba2051ef58510eb87baa8fe7748d0d781ef350075365bf444caf4d",
    "61a7a5589892f03e7c4b03b1a1626985661d07e55cab5564a581d6493dedde63",
    "c0cb4d7c6750f790aa4a73ee35d63c7d770423aff4a92b7fa1b2e05f5e0c8b7f",
    "13cfe790530a34558e2a060589c32d3aec6ab738787f47766fe4d9b876396154",
    "7deca83ef54cf2ac9ab7ef3a47a8ed407c18fd23350ea7eb3c9cf819f28f7b4b",
    "afb53cf7ce9d5305b226aed73926d2f62228936fee3142619ea288a03417d301",
    VECTOR_SHA,
]
FROZEN_INPUTS = {
    "Tests/BrowserAppTests/NativeBitwardenWriteTests.swift": "62b59c6a0c6fa66790093ed3f3b0c6f6ef245bf93a4ccd65056a6a04d6e5c488",
    "Sources/ArcusisBrowser/NativeBitwardenWrites.swift": "208fa3b29c8163ce6bf10ad0a785b1e5fa3636c92a0a9ceaa4d420250e509176",
    "Sources/ArcusisBrowser/NativeBitwardenBackend.swift": "8180639f25c7948f3ae63f629ddd5536c226dc901fd29ab3b9ece04f972612e6",
    "Sources/ArcusisBrowser/NativeBitwardenCipherRepository.swift": "d2baa793bcd6360ed24856404bf86889c40984776ffbd603c718138e91e6041d",
    "Tests/BrowserAppTests/NativeBitwardenCipherRepositoryTests.swift": "b0a0e891efc6c2dc3db2b8d7b84255c3b8652be6571f0cf06f7492c701cee128",
    "Tests/BrowserAppTests/NativeBitwardenCipherWriteTests.swift": "91405b39995f3401e77c4a1ed05a34cda75e756f3bc283eabacee21d18b6c32f",
}
PACKAGE_SWIFT = '''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "ArcusisBrowser", platforms: [.macOS("26.0")],
  dependencies: [.package(name: "SDKPackage", path: "../SDKPackage")], targets: [
    .target(name: "BrowserCore", resources: [.process("Resources/public_suffix_list.dat")]),
    .target(name: "ArcusisBrowser", dependencies: ["BrowserCore", .product(name: "ArcusisBitwardenSDK", package: "SDKPackage")], swiftSettings: [.define("ARCUSIS_NATIVE_BITWARDEN_ORGANIZATION_CANDIDATE"), .define("ARCUSIS_NATIVE_BITWARDEN_REFRESH_CANDIDATE"), .define("ARCUSIS_NATIVE_BITWARDEN_REFRESH_FIXTURE")]),
    .testTarget(name: "BrowserAppTests", dependencies: ["ArcusisBrowser", "BrowserCore", .product(name: "ArcusisBitwardenSDK", package: "SDKPackage")], swiftSettings: [.define("ARCUSIS_NATIVE_BITWARDEN_REFRESH_FIXTURE")]),
  ])
'''


def reject_symlink_components(path: Path) -> None:
    if not path.is_absolute():
        raise RuntimeError("input path must be absolute")
    for part in (path, *path.parents):
        if part.is_symlink():
            raise RuntimeError("input symlink rejected")


def checked_path(base: Path, relative: str) -> Path:
    """Reject symlinks in the selected root and every relative component."""
    reject_symlink_components(base)
    if not base.is_dir():
        raise RuntimeError("invalid input root")
    parts = Path(relative).parts
    if not parts or Path(relative).is_absolute() or any(part in (".", "..") for part in parts):
        raise RuntimeError("invalid input path")
    path = base
    for part in parts:
        path = path / part
        if path.is_symlink():
            raise RuntimeError("input symlink rejected")
    return path


def digest(path: Path) -> str:
    if path.is_symlink() or not path.is_file():
        raise RuntimeError(f"invalid input: {path.name}")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def package_inventory(path: Path) -> dict[str, str]:
    manifest_path = checked_path(path, "fixture-manifest.json")
    if digest(manifest_path) != MANIFEST_SHA:
        raise RuntimeError("fixture manifest mismatch")
    manifest = json.loads(manifest_path.read_text())
    if (manifest.get("accepted") is not False or manifest.get("integration_ready") is not False
            or manifest.get("testOnly") is not True or manifest.get("profile") != "debug"
            or manifest.get("architecture") != "arm64"
            or manifest.get("sourceCommit") != "5cf919837e83b71c2508bf99344ea57cf5f84e88"):
        raise RuntimeError("fixture provenance mismatch")
    actual = {}
    for item in path.rglob("*"):
        if item.is_symlink():
            raise RuntimeError("fixture symlink rejected")
        if item.is_file() and item != manifest_path:
            actual[item.relative_to(path).as_posix()] = digest(item)
        elif not item.is_file() and not item.is_dir():
            raise RuntimeError("fixture special file rejected")
    if actual != manifest.get("fileSHA256") or len(actual) != 83:
        raise RuntimeError("fixture inventory mismatch")
    return actual


def clean_environment() -> dict[str, str]:
    return {key: os.environ[key] for key in ("PATH", "HOME", "TMPDIR") if key in os.environ}


def input_fingerprints() -> dict[str, object]:
    reject_symlink_components(EXTRACTOR)
    reject_symlink_components(Path(__file__).absolute())
    source = {name: digest(checked_path(ROOT, name)) for name in INPUTS}
    if any(source.get(name) != expected for name, expected in FROZEN_INPUTS.items()):
        raise RuntimeError("frozen source mismatch")
    audit = {name: digest(checked_path(SOURCE, name)) for name in AUDIT_INPUTS}
    if audit != dict(zip(AUDIT_INPUTS, AUDIT_SHA)) or digest(EXTRACTOR) != EXTRACTOR_SHA:
        raise RuntimeError("public vector source mismatch")
    return {"source": source, "audit": audit, "sdk": package_inventory(SDK_SOURCE),
            "sdkManifest": MANIFEST_SHA, "runner": digest(Path(__file__)),
            "extractor": EXTRACTOR_SHA}


def fingerprints() -> dict[str, object]:
    original = input_fingerprints()
    if original["sdk"] != package_inventory(SDK_COPY):
        raise RuntimeError("copied SDK mismatch")
    copied = {name: digest(checked_path(HARNESS, name)) for name in INPUTS}
    if original["source"] != copied or digest(HARNESS / "Package.swift") != hashlib.sha256(PACKAGE_SWIFT.encode()).hexdigest():
        raise RuntimeError("harness input mismatch")
    # No unlisted files may enter the staged source directories.
    for directory in ("Sources", "Tests"):
        actual = {p.relative_to(HARNESS).as_posix() for p in (HARNESS / directory).rglob("*")
                  if p.is_file() or p.is_symlink()}
        expected = {name for name in INPUTS if name.startswith(directory + "/")}
        if actual != expected or any(p.is_symlink() for p in (HARNESS / directory).rglob("*")):
            raise RuntimeError("harness source inventory mismatch")
    return {**original, "harnessManifest": digest(HARNESS / "Package.swift")}


def setup() -> None:
    # OUTPUT is a fresh private temporary directory, never an existing build.
    shutil.copytree(SDK_SOURCE, SDK_COPY)
    for name in INPUTS:
        source = checked_path(ROOT, name)
        destination = HARNESS / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
    (HARNESS / "Package.swift").write_text(PACKAGE_SWIFT)


def group_exists(pgid: int) -> bool:
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False


def run_owned(command: list[str], environment: dict[str, str], timeout: float,
              nofork: bool = False) -> bytes:
    process = subprocess.Popen(command, cwd=ROOT, env=environment, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, start_new_session=True)
    try:
        output, _ = process.communicate(timeout=timeout)
        if process.returncode != 0:
            raise RuntimeError("owned command failed\n" + output.decode(errors="replace")[-12000:])
        return output
    finally:
        live = process.poll() is None
        if live and os.getpgid(process.pid) != process.pid:
            raise RuntimeError("owned process identity changed")
        if nofork and not live and group_exists(process.pid):
            raise RuntimeError("exited sandbox group remains unverifiable")
        if group_exists(process.pid) and (live or not nofork):
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                pass
            if group_exists(process.pid) and (not nofork or process.poll() is None):
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        process.wait(timeout=3)
        deadline = time.monotonic() + 3
        while group_exists(process.pid) and time.monotonic() < deadline:
            time.sleep(0.05)
        if group_exists(process.pid):
            raise RuntimeError("owned process group survived cleanup")
        if process.stdout is not None:
            process.stdout.close()


def verify_sandbox() -> None:
    control = '''import errno, os
try:
 os.fork()
except OSError as error:
 assert error.errno == errno.EPERM
else:
 raise SystemExit(1)
try:
 os.posix_spawn("/usr/bin/true", ["true"], {"PATH": "/usr/bin:/bin"})
except OSError as error:
 assert error.errno == errno.EPERM
else:
 raise SystemExit(1)
print("spawn_denied")
'''
    output = run_owned([SANDBOX, "-p", POLICY, sys.executable, "-c", control],
                       clean_environment(), 10, nofork=True)
    if output != b"spawn_denied\n":
        raise RuntimeError("sandbox control failed")


def verify_process_cleanup() -> None:
    sleeper = [SANDBOX, "-p", POLICY, sys.executable, "-c", "import time; time.sleep(10)"]
    try:
        run_owned(sleeper, clean_environment(), 0.2, nofork=True)
        raise RuntimeError("timeout control unexpectedly completed")
    except subprocess.TimeoutExpired:
        pass
    try:
        with patch.object(subprocess.Popen, "communicate", side_effect=KeyboardInterrupt()):
            run_owned(sleeper, clean_environment(), 10, nofork=True)
        raise RuntimeError("interrupt control unexpectedly completed")
    except KeyboardInterrupt:
        pass
    try:
        run_owned([SANDBOX, "-p", POLICY, sys.executable, "-c", "raise SystemExit(7)"],
                  clean_environment(), 10, nofork=True)
        raise RuntimeError("error control unexpectedly completed")
    except RuntimeError as error:
        if not str(error).startswith("owned command failed"):
            raise


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

    def handle_write(self, method: str) -> None:
        try:
            if (self.client_address[0] != "127.0.0.1" or self.headers.get("Transfer-Encoding")
                    or self.headers.get("Authorization") != ("Bearer " + (self.server.access_token if self.server.backend_fixture else "synthetic-owned-token"))):
                raise ValueError("request boundary")
            length = int(self.headers.get("Content-Length", "-1"))
            if not 0 <= length <= (1_200_000 if self.server.size_case else 65536):
                raise ValueError("request length")
            raw = self.rfile.read(length)
            obj = json.loads(raw)
            if any(value in raw for value in (b"fixture-write-user", b"fixture-write-first",
                                               b"fixture-write-second", b"fixture-write-third",
                                               b"fixture-custom", b"fixture-name", b"fixture-notes",
                                               b"fixture.example/login")):
                raise ValueError("plaintext secret in request")
            login = obj.get("login")
            if not isinstance(login, dict) or not all(isinstance(login.get(field), str)
                                                       and login[field].startswith("2.")
                                                       for field in ("username", "password")):
                raise ValueError("missing encrypted login")
            if self.server.size_case and (not isinstance(obj.get("notes"), str) or not obj["notes"].startswith("2.")):
                raise ValueError("missing encrypted large notes")
            if method == "POST" and self.path == "/api/ciphers":
                self.server.counts["create"] += 1
                expected_creates = 1 if self.server.size_case == "single" else 18 if self.server.size_case == "aggregate" else 1
                if self.server.counts["create"] > expected_creates:
                    raise ValueError("duplicate create")
                revision = "2025-01-04T00:00:00Z" if self.server.backend_fixture else "2025-01-01T00:00:00Z"
            elif method == "PUT" and self.path == "/api/ciphers/" + CIPHER_ID:
                self.server.counts["edit"] += 1
                count = self.server.counts["edit"]
                expected = ("2025-01-02T00:00:00Z" if count == 1 else "2025-01-03T00:00:00Z") if self.server.backend_fixture else ("2025-01-01T00:00:00Z" if count <= 2 else "2025-01-02T00:00:00Z")
                if obj.get("lastKnownRevisionDate") != expected:
                    actual = obj.get("lastKnownRevisionDate")
                    if not isinstance(actual, str) or not re.fullmatch(r"[0-9TZ:.-]{1,40}", actual):
                        actual = "invalid"
                    raise ValueError("revision mismatch " + actual)
                if self.server.backend_fixture and count == 2:
                    self.server.write_started.set()
                    if not self.server.write_release.wait(timeout=8):
                        raise ValueError("write control timeout")
                elif count in (2, 3, 4):
                    self.reply({2: 409, 3: 401, 4: 403}[count], {"message": "synthetic rejection"})
                    return
                if count == 5:
                    self.server.ambiguous_received = True
                    self.close_connection = True
                    self.connection.shutdown(socket.SHUT_RDWR)
                    return
                if count != 1 and not (self.server.backend_fixture and count == 2):
                    raise ValueError("duplicate edit")
                revision = "2025-01-03T00:00:00Z" if self.server.backend_fixture else "2025-01-02T00:00:00Z"
            else:
                raise ValueError("unexpected request")
            result = dict(obj)
            result_id = (f"00000000-0000-4000-8000-{self.server.counts['create']:012d}"
                         if self.server.size_case else CREATED_ID if self.server.backend_fixture and method == "POST" else CIPHER_ID)
            result.update({"object": "cipher", "id": result_id, "creationDate": "2025-01-01T00:00:00Z",
                           "revisionDate": revision, "edit": True, "viewPassword": True})
            result["collectionIds"] = []
            self.server.sync_cipher = result
            if self.server.size_case:
                self.server.size_ciphers.append(result)
            self.reply(200, result)
        except (OSError, ValueError, KeyError, TypeError) as error:
            self.server.errors.append(type(error).__name__ + ":" + str(error))
            try:
                self.reply(400, {})
            except OSError:
                pass

    def do_POST(self) -> None:
        if self.path in ("/identity/accounts/prelogin/password", "/identity/connect/token"):
            self.handle_auth()
            return
        self.handle_write("POST")

    def do_PUT(self) -> None:
        self.handle_write("PUT")

    def handle_auth(self) -> None:
        try:
            if self.client_address[0] != "127.0.0.1" or self.headers.get("Transfer-Encoding"):
                raise ValueError("auth boundary")
            length = int(self.headers.get("Content-Length", "-1"))
            if not 0 <= length <= 65536:
                raise ValueError("auth length")
            body = self.rfile.read(length)
            if self.path == "/identity/accounts/prelogin/password":
                if json.loads(body).get("email") != self.server.vector["email"]:
                    raise ValueError("prelogin input")
                self.server.counts["prelogin"] += 1
                self.reply(200, {"kdfSettings": {"kdfType": 0,
                          "iterations": self.server.vector["iterations"]},
                          "salt": self.server.vector["email"]})
            else:
                form = parse_qs(body.decode(), keep_blank_values=True)
                if form.get("grant_type") != ["password"] or form.get("client_id") != ["desktop"]:
                    raise ValueError("login input")
                self.server.counts["login"] += 1
                self.reply(200, self.server.login_response)
        except (OSError, ValueError, KeyError, TypeError) as error:
            self.server.errors.append(type(error).__name__ + ":" + str(error))
            try:
                self.reply(400, {})
            except OSError:
                pass

    def do_GET(self) -> None:
        if self.server.backend_fixture and self.path in ("/fixture/status", "/fixture/release"):
            if self.client_address[0] != "127.0.0.1":
                self.server.errors.append("control boundary")
                self.reply(400, {})
                return
            self.server.controls += 1
            if self.server.controls > 45:
                self.server.errors.append("excess controls")
                self.reply(400, {})
                return
            if self.path == "/fixture/release":
                self.server.write_release.set()
            body = b"ready" if self.server.write_started.is_set() else b"waiting"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if (self.client_address[0] != "127.0.0.1" or not self.path.startswith("/api/sync")
                or self.headers.get("Authorization") != "Bearer " + self.server.access_token):
            self.server.errors.append("sync boundary")
            self.reply(400, {})
            return
        self.server.counts["sync"] += 1
        if self.server.counts["sync"] == 3 and not self.server.backend_fixture:
            self.reply(403, {})
            return
        if self.server.counts["sync"] > 3:
            self.server.errors.append("duplicate sync")
            self.reply(400, {})
            return
        if self.server.sync_cipher is None:
            self.server.errors.append("missing synthetic encrypted cipher")
            self.reply(400, {})
            return
        self.reply(200, {"profile": {"id": self.server.vector["userID"],
                   "email": self.server.vector["email"], "emailVerified": True,
                   "organizationsNew": []}, "folders": [], "ciphers": self.server.size_ciphers if self.server.size_case else [self.server.sync_cipher], "sends": [],
                   "policiesNew": [], "userDecryption": {}})


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = False
    daemon_threads = True

    def __init__(self) -> None:
        super().__init__(("127.0.0.1", 0), Handler)
        self.counts = {"create": 0, "edit": 0, "prelogin": 0, "login": 0, "sync": 0}
        self.backend_fixture = False
        self.size_case: str | None = None
        self.size_ciphers: list[dict[str, object]] = []
        self.controls = 0
        self.write_started = threading.Event()
        self.write_release = threading.Event()
        self.ambiguous_received = False
        self.sync_cipher: dict[str, object] | None = None
        self.errors: list[str] = []
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


def run(baseline: dict[str, object]) -> None:
    setup()
    before = fingerprints()
    if {key: before[key] for key in baseline} != baseline:
        raise RuntimeError("inputs changed during staging")
    vector_spec = importlib.util.spec_from_file_location("owned_vector", EXTRACTOR)
    if vector_spec is None or vector_spec.loader is None:
        raise RuntimeError("vector extractor unavailable")
    module = importlib.util.module_from_spec(vector_spec)
    vector_spec.loader.exec_module(module)
    vector = module.sdk_vector(SOURCE)
    text = (SOURCE / AUDIT_INPUTS[-1]).read_text()
    section = text.split("INSERT INTO vault_dev.dbo.[User]", 1)[1].split(
        "INSERT INTO vault_dev.dbo.Organization", 1)[0]
    match = re.search(r"N\s*'(MIIBIjAN[^']+)'", section)
    if not match:
        raise RuntimeError("public key fixture unavailable")
    payload = json.dumps({"sub": vector["userID"], "client_id": "desktop",
                          "exp": int(time.time()) + 3600, "scope": ["api"]}).encode()
    token = "e30." + base64.urlsafe_b64encode(payload).decode().rstrip("=") + ".c2ln"
    login_response = {
        "access_token": token, "expires_in": 3600, "token_type": "Bearer",
        "refresh_token": "synthetic-initial", "scope": "api offline_access",
        "PrivateKey": vector["privateKey"],
        "AccountKeys": {"publicKeyEncryptionKeyPair": {"wrappedPrivateKey": vector["privateKey"],
                        "publicKey": match.group(1), "Object": "publicKeyEncryptionKeyPair"},
                        "Object": "privateKeys"},
        "Key": vector["wrappedUserKey"], "MasterPasswordPolicy": {"Object": "masterPasswordPolicy"},
        "ForcePasswordReset": False, "Kdf": 0, "KdfIterations": vector["iterations"],
        "KdfMemory": None, "KdfParallelism": None,
        "UserDecryptionOptions": {"HasMasterPassword": True,
            "MasterPasswordUnlock": {"Kdf": {"KdfType": 0, "Iterations": vector["iterations"]},
                "MasterKeyEncryptedUserKey": vector["wrappedUserKey"], "Salt": vector["email"]},
            "Object": "userDecryptionOptions"},
    }
    verify_sandbox()
    verify_process_cleanup()
    if before != fingerprints():
        raise RuntimeError("inputs changed before build")
    command = ["swift", "build", "--package-path", str(HARNESS), "--build-tests", "--jobs", "2",
               "--disable-keychain", "--disable-netrc", "--disable-dependency-cache",
               "--disable-prefetching", "--manifest-cache", "none"]
    run_owned(command, clean_environment(), 300)
    if before != fingerprints():
        raise RuntimeError("build inputs changed")
    bundle = HARNESS / ".build/out/Products/Debug/BrowserAppTests.xctest"
    binary = bundle / "Contents/MacOS/BrowserAppTests"
    built_hash = digest(binary)
    input_result = run_owned([SANDBOX, "-p", POLICY, str(XCTEST), "-XCTest",
                              "BrowserAppTests.NativeBitwardenWriteTests/testInputBoundsAndRedaction",
                              str(bundle)], clean_environment(), 30, nofork=True)
    if b"Executed 1 test, with 0 failures" not in input_result:
        raise RuntimeError("missing write-input XCTest success")
    if before != fingerprints() or digest(binary) != built_hash:
        raise RuntimeError("inputs changed during write-input test")
    print("write_input_xctest=passed")
    server = Server()
    server.vector, server.access_token, server.login_response = vector, token, login_response
    address = server.server_address
    server.timeout = 0.1
    stop = threading.Event()
    thread = threading.Thread(target=lambda: serve(server, stop), daemon=True)
    started = False
    try:
        thread.start()
        started = True
        vector["endpoint"] = f"http://127.0.0.1:{address[1]}"
        environment = clean_environment()
        environment["ARCUSIS_CIPHER_WRITE_FIXTURE"] = base64.b64encode(json.dumps(vector).encode()).decode()
        result = run_owned([SANDBOX, "-p", POLICY, str(XCTEST), "-XCTest",
                            "BrowserAppTests.NativeBitwardenCipherWriteTests/testOwnedSDKCipherCreateEditAndFailures",
                            str(bundle)], environment, 90, nofork=True)
        if b"Executed 1 test, with 0 failures" not in result:
            raise RuntimeError("missing named XCTest success")
        lifecycle = run_owned([SANDBOX, "-p", POLICY, str(XCTEST), "-XCTest",
                               "BrowserAppTests.NativeBitwardenCipherWriteTests/testOwnedBackendRepositoryLifecycle",
                               str(bundle)], environment, 90, nofork=True)
        if b"Executed 1 test, with 0 failures" not in lifecycle:
            raise RuntimeError("missing backend lifecycle XCTest success")
        if (server.counts != {"create": 1, "edit": 5, "prelogin": 1, "login": 1, "sync": 3}
                or not server.ambiguous_received
                or server.errors):
            raise RuntimeError(f"fixture counts/errors: {server.counts} {server.errors}")
        if before != fingerprints() or digest(binary) != built_hash:
            raise RuntimeError("fixture inputs changed during run")
        print("input_fingerprints=" + json.dumps(before, sort_keys=True))
        print("sandbox=passed")
        print("cleanup_controls=passed")
        print("build=passed")
        print("xctest=passed")
        print("backend_lifecycle=passed")
        print("request_counts=" + json.dumps(server.counts, sort_keys=True))
        print("test_binary_sha256=" + built_hash)
    finally:
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
        if thread.is_alive() or any(worker.is_alive() for worker in threads) or not closed:
            raise RuntimeError("owned listener cleanup failed")
        print("request_counts=" + json.dumps(server.counts, sort_keys=True))
        print("fixture_errors=" + json.dumps(server.errors))
        if before != fingerprints() or digest(binary) != built_hash:
            raise RuntimeError("fixture inputs changed during run or cleanup")
        print("owned_cleanup=passed")

    run_backend_fixture(vector, login_response, token, server.sync_cipher, before, binary, built_hash)
    for size_case in ("single", "aggregate"):
        run_size_fixture(size_case, vector, login_response, token, before, binary, built_hash)


def run_backend_fixture(vector: dict[str, object], login_response: dict[str, object], token: str,
                        seed: dict[str, object] | None, before: dict[str, object],
                        binary: Path, built_hash: str) -> None:
    if seed is None:
        raise RuntimeError("backend synthetic seed unavailable")
    server = Server()
    server.backend_fixture = True
    server.sync_cipher = seed
    server.vector, server.access_token, server.login_response = vector, token, login_response
    address = server.server_address
    server.timeout = 0.1
    stop = threading.Event()
    thread = threading.Thread(target=lambda: serve(server, stop), daemon=True)
    started = False
    try:
        thread.start()
        started = True
        vector["endpoint"] = f"http://127.0.0.1:{address[1]}"
        environment = clean_environment()
        environment["ARCUSIS_CIPHER_WRITE_FIXTURE"] = base64.b64encode(json.dumps(vector).encode()).decode()
        bundle = HARNESS / ".build/out/Products/Debug/BrowserAppTests.xctest"
        result = run_owned([SANDBOX, "-p", POLICY, str(XCTEST), "-XCTest",
                            "BrowserAppTests.NativeBitwardenCipherWriteTests/testOwnedBackendWritesAndDelayedLock",
                            str(bundle)], environment, 90, nofork=True)
        if b"Executed 1 test, with 0 failures" not in result:
            raise RuntimeError("missing backend write XCTest success")
        if server.counts != {"create": 1, "edit": 2, "prelogin": 1, "login": 1, "sync": 3} or server.errors:
            raise RuntimeError(f"backend counts/errors: {server.counts} {server.errors}")
        if before != fingerprints() or digest(binary) != built_hash:
            raise RuntimeError("backend fixture inputs changed")
        print("backend_write_xctest=passed")
        print("backend_write_counts=" + json.dumps(server.counts, sort_keys=True))
    finally:
        server.write_release.set()
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
        if thread.is_alive() or any(worker.is_alive() for worker in threads) or not closed:
            raise RuntimeError("backend listener cleanup failed")
        if before != fingerprints() or digest(binary) != built_hash:
            raise RuntimeError("backend fixture inputs changed during cleanup")
        print("backend_owned_cleanup=passed")


def run_size_fixture(size_case: str, vector: dict[str, object], login_response: dict[str, object],
                     token: str, before: dict[str, object], binary: Path, built_hash: str) -> None:
    server = Server()
    server.size_case = size_case
    server.vector, server.access_token, server.login_response = vector, token, login_response
    address = server.server_address
    server.timeout = 0.1
    stop = threading.Event()
    thread = threading.Thread(target=lambda: serve(server, stop), daemon=True)
    started = False
    try:
        thread.start()
        started = True
        vector["endpoint"] = f"http://127.0.0.1:{address[1]}"
        vector["sizeCase"] = size_case
        environment = clean_environment()
        environment["ARCUSIS_CIPHER_WRITE_FIXTURE"] = base64.b64encode(json.dumps(vector).encode()).decode()
        bundle = HARNESS / ".build/out/Products/Debug/BrowserAppTests.xctest"
        result = run_owned([SANDBOX, "-p", POLICY, str(XCTEST), "-XCTest",
                            "BrowserAppTests.NativeBitwardenCipherWriteTests/testOwnedBackendReadWhenWritableLimitExceeded",
                            str(bundle)], environment, 90, nofork=True)
        if b"Executed 1 test, with 0 failures" not in result:
            raise RuntimeError("missing size-limit XCTest success")
        expected = {"create": 1 if size_case == "single" else 18, "edit": 0,
                    "prelogin": 1, "login": 1, "sync": 1}
        if server.counts != expected or server.errors:
            raise RuntimeError(f"size fixture counts/errors: {server.counts} {server.errors}")
        if before != fingerprints() or digest(binary) != built_hash:
            raise RuntimeError("size fixture inputs changed")
        print("size_" + size_case + "_xctest=passed")
        print("size_" + size_case + "_counts=" + json.dumps(server.counts, sort_keys=True))
    finally:
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
        if thread.is_alive() or any(worker.is_alive() for worker in threads) or not closed:
            raise RuntimeError("size listener cleanup failed")
        if before != fingerprints() or digest(binary) != built_hash:
            raise RuntimeError("size fixture inputs changed during cleanup")
        print("size_" + size_case + "_cleanup=passed")


def serve(server: Server, stop: threading.Event) -> None:
    while not stop.is_set():
        server.handle_request()


def absolute_argument(value: str) -> Path:
    path = Path(value)
    if not path.is_absolute():
        raise argparse.ArgumentTypeError("input path must be absolute")
    return path


def main() -> None:
    global SDK_SOURCE, SOURCE, EXTRACTOR, OUTPUT, HARNESS, SDK_COPY
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk-package", type=absolute_argument, default=SDK_SOURCE)
    parser.add_argument("--sdk-source", type=absolute_argument, default=SOURCE)
    parser.add_argument("--extractor", type=absolute_argument, default=EXTRACTOR)
    args = parser.parse_args()
    SDK_SOURCE, SOURCE, EXTRACTOR = args.sdk_package, args.sdk_source, args.extractor
    baseline = input_fingerprints()
    scratch_root = ROOT / "build/NativeBitwardenCipherRepository/runs"
    reject_symlink_components(scratch_root)
    scratch_root.mkdir(parents=True, exist_ok=True)
    reject_symlink_components(scratch_root)
    try:
        with tempfile.TemporaryDirectory(prefix="cipher-write-", dir=scratch_root) as scratch:
            OUTPUT = Path(scratch)
            HARNESS, SDK_COPY = OUTPUT / "harness", OUTPUT / "SDKPackage"
            run(baseline)
    finally:
        if baseline != input_fingerprints():
            raise RuntimeError("inputs changed during scratch cleanup")
    print("scratch_cleanup=passed")


if __name__ == "__main__":
    main()
