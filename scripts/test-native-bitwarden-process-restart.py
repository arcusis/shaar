#!/usr/bin/env python3
# Owned two-process SDK7 debug restart proof; no production credentials.
from __future__ import annotations

import argparse
import base64
import hashlib
import importlib.util
import json
import os
import re
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path
from urllib.parse import parse_qs

ROOT = Path(__file__).resolve().parents[1]
BASE_RUNNER = ROOT / "scripts/test-native-bitwarden-refresh.py"
RELEASE = ROOT / "build/NativeBitwardenRefreshSDK7/Package"
DEBUG = ROOT / "build/NativeBitwardenRefreshSDK7Fixture/Package"
RELEASE_HASH = "dd2e42bb29bf52f94d9f6ee64fcb6a7f5ab6f09b18dda75b7b01432afe299d15"
DEBUG_HASH = "eb223e86bea215843191ccb01f94ff290e629f98063de0336ee51d3d9249b039"
SCRATCH = ROOT / "build/IndependentSDK7Acceptance" / ("fixture-" + uuid.uuid4().hex)
BUNDLE = SCRATCH / "out/Products/Debug/BrowserAppTests.xctest"
BINARY = BUNDLE / "Contents/MacOS/BrowserAppTests"
RECEIPT = ROOT / "build/IndependentSDK7Acceptance/receipt.json"

# Imported only after the explicitly pinned source checkpoint has been checked.
base = None
SOURCE_MANIFEST: Path
SOURCE_MANIFEST_SHA256: str
HEX256 = re.compile(r"[0-9a-f]{64}\Z")
HEX40 = re.compile(r"[0-9a-f]{40}\Z")
SOURCE_SCRIPTS = (
    "scripts/test-native-bitwarden-refresh.py",
    "scripts/test-native-bitwarden-process-restart.py",
    "scripts/test-native-bitwarden-sync.py",
)


def digest(path: Path) -> str:
    if not stat.S_ISREG(path.lstat().st_mode):
        raise RuntimeError("invalid input file")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def reject_duplicates(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result = {}
    for key, value in pairs:
        if key in result:
            raise RuntimeError("duplicate manifest key")
        result[key] = value
    return result


def safe_file(root: Path, name: str) -> Path:
    if not isinstance(name, str) or not name or "\\" in name or "\x00" in name:
        raise RuntimeError("unsafe source path")
    parts = name.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise RuntimeError("unsafe source path")
    path = root
    for index, part in enumerate(parts):
        path = path / part
        mode = path.lstat().st_mode
        if index < len(parts) - 1:
            if not stat.S_ISDIR(mode):
                raise RuntimeError("unsafe source directory")
        elif not stat.S_ISREG(mode):
            raise RuntimeError("unsafe source file")
    return path


def walk_error(error: OSError) -> None:
    raise error


def source_inventory(root: Path) -> set[str]:
    files = {"Package.swift", *SOURCE_SCRIPTS}
    for name in files.copy():
        safe_file(root, name)
    for name in ("Sources", "Tests"):
        directory = root / name
        if not stat.S_ISDIR(directory.lstat().st_mode):
            raise RuntimeError("unsafe source directory")
        for parent, dirs, names in os.walk(directory, followlinks=False, onerror=walk_error):
            for entry in dirs:
                if not stat.S_ISDIR((Path(parent) / entry).lstat().st_mode):
                    raise RuntimeError("unsafe source directory")
            for entry in names:
                path = Path(parent) / entry
                if not stat.S_ISREG(path.lstat().st_mode):
                    raise RuntimeError("unsafe source file")
                files.add(path.relative_to(root).as_posix())
    return files


def validate_source_manifest(root: Path, manifest_path: Path, expected: str) -> dict[str, str]:
    if not HEX256.fullmatch(expected):
        raise RuntimeError("invalid manifest digest")
    verification = root / "build/Verification"
    if not manifest_path.is_absolute() or manifest_path != manifest_path.resolve():
        raise RuntimeError("manifest path is not canonical")
    if not manifest_path.is_relative_to(verification.resolve()) or manifest_path == verification.resolve():
        raise RuntimeError("manifest outside verification directory")
    safe_file(root, manifest_path.relative_to(root).as_posix())
    if digest(manifest_path) != expected:
        raise RuntimeError("source manifest digest mismatch")
    manifest = json.loads(manifest_path.read_text(), object_pairs_hook=reject_duplicates)
    if (not isinstance(manifest, dict) or set(manifest) != {"schema", "sourceCommit", "files"}
            or type(manifest["schema"]) is not int or manifest["schema"] != 1
            or not isinstance(manifest["sourceCommit"], str)
            or not HEX40.fullmatch(manifest["sourceCommit"])
            or not isinstance(manifest["files"], dict)):
        raise RuntimeError("invalid source manifest")
    head = subprocess.run(["git", "rev-parse", "--verify", "HEAD"], cwd=root,
                          env={key: os.environ[key] for key in ("PATH", "HOME", "TMPDIR") if key in os.environ},
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, text=True).stdout.strip()
    if head != manifest["sourceCommit"]:
        raise RuntimeError("source HEAD mismatch")
    inventory = source_inventory(root)
    files = manifest["files"]
    if set(files) != inventory:
        raise RuntimeError("source inventory mismatch")
    for name, expected_hash in files.items():
        if not isinstance(expected_hash, str) or not HEX256.fullmatch(expected_hash):
            raise RuntimeError("invalid source hash")
        if digest(safe_file(root, name)) != expected_hash:
            raise RuntimeError("source payload mismatch")
    return files


def load_helper() -> None:
    global base
    spec = importlib.util.spec_from_file_location("refresh_fixture_runner", BASE_RUNNER)
    if spec is None or spec.loader is None:
        raise RuntimeError("fixture helper unavailable")
    base = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(base)


def validate_package(root: Path, manifest_name: str, expected: str, fixture: bool) -> None:
    manifest_path = root / manifest_name
    if base.digest(manifest_path) != expected:
        raise RuntimeError("package manifest mismatch")
    manifest = json.loads(manifest_path.read_text())
    if (manifest.get("accepted") is not False or manifest.get("integration_ready") is not False
            or manifest.get("architecture") != "arm64" or manifest.get("minMacOS") != "26.0"
            or manifest.get("sourceCommit") != "5cf919837e83b71c2508bf99344ea57cf5f84e88"):
        raise RuntimeError("package identity mismatch")
    if fixture and (manifest.get("testOnly") is not True or manifest.get("profile") != "debug"):
        raise RuntimeError("debug fixture identity mismatch")
    inventory = manifest.get("fileSHA256")
    if not isinstance(inventory, dict) or len(inventory) != 83:
        raise RuntimeError("package inventory mismatch")
    files = set()
    for path in root.rglob("*"):
        if path.is_symlink():
            raise RuntimeError("package symlink rejected")
        mode = path.lstat().st_mode
        if not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
            raise RuntimeError("package special file rejected")
        if stat.S_ISREG(mode) and path != manifest_path:
            files.add(path.relative_to(root).as_posix())
    if files != set(inventory):
        raise RuntimeError("package inventory changed")
    for name, value in inventory.items():
        path = root / name
        if not path.resolve().is_relative_to(root.resolve()) or base.digest(path) != value:
            raise RuntimeError("package payload changed")


def fingerprints() -> dict[str, object]:
    sources = validate_source_manifest(ROOT, SOURCE_MANIFEST, SOURCE_MANIFEST_SHA256)
    validate_package(RELEASE, "build-manifest.json", RELEASE_HASH, False)
    validate_package(DEBUG, "fixture-manifest.json", DEBUG_HASH, True)
    vector = base.digest(base.SOURCE / "crates/bitwarden-core/src/client/test_accounts.rs")
    extractor = base.digest(base.VECTOR_RUNNER)
    if vector != base.VECTOR_HASH or extractor != base.EXTRACTOR_HASH:
        raise RuntimeError("public fixture or extractor hash mismatch")
    return {"sources": sources, "sourceCommit": subprocess.run(
                ["git", "rev-parse", "--verify", "HEAD"], cwd=ROOT,
                env=base.clean_environment(), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                check=True, text=True).stdout.strip(),
            "sourceManifestSHA256": SOURCE_MANIFEST_SHA256,
            "runner": base.digest(Path(__file__)), "helper": base.digest(BASE_RUNNER),
            "vector": vector, "extractor": extractor,
            "release": RELEASE_HASH, "debug": DEBUG_HASH}


def cleanup_sandbox_child(child: subprocess.Popen[bytes]) -> None:
    # The verified sandbox denies process creation, so an exited test host has
    # no owned descendants; never signal a potentially recycled group ID.
    try:
        if child.poll() is None:
            base.terminate_owned_group(child)
        elif base.process_group_exists(child.pid):
            raise RuntimeError("exited sandbox group still exists")
    finally:
        if child.stdout is not None:
            child.stdout.close()


def run_owned(command: list[str], environment: dict[str, str], timeout: float) -> tuple[int, bytes, int]:
    child = subprocess.Popen(command, cwd=ROOT, env=environment, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, start_new_session=True)
    try:
        output, _ = child.communicate(timeout=timeout)
        return child.returncode, output, child.pid
    finally:
        cleanup_sandbox_child(child)


def verify_sandbox() -> None:
    source = r'''import errno, os
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
    code, output, _ = run_owned(
        [base.SANDBOX, "-p", base.POLICY, sys.executable, "-c", source],
        base.clean_environment(), 10)
    if code != 0 or output != b"spawn_denied\n":
        raise RuntimeError("sandbox control failed")


def server_class():
    class Handler(base.Handler):
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
                    with self.server.lock:
                        self.server.counts["prelogin"] += 1
                    self.reply(200, {"kdfSettings": {"kdfType": 0,
                               "iterations": self.server.vector["iterations"]},
                               "salt": self.server.vector["email"]})
                elif self.path == "/identity/connect/token":
                    form = parse_qs(body.decode(), keep_blank_values=True)
                    grant = form.get("grant_type", [""])[0]
                    if form.get("client_id") != ["desktop"]:
                        self.reply(400, {})
                    elif grant == "password":
                        with self.server.lock:
                            self.server.counts["login"] += 1
                            count = self.server.counts["login"]
                            response = dict(self.server.login_response)
                            if count == 2:
                                self.server.refresh_token = "synthetic-fresh-login"
                                self.server.access_token = base.token(
                                    str(self.server.vector["userID"]), int(time.time()) + 3600, "fresh-login")
                                response.update(access_token=self.server.access_token,
                                                refresh_token=self.server.refresh_token, expires_in=3600)
                            elif count != 1:
                                self.reply(400, {})
                                return
                        self.reply(200, response)
                    elif grant == "refresh_token":
                        with self.server.lock:
                            self.server.refresh_attempts += 1
                            if form.get("refresh_token") != [self.server.refresh_token]:
                                self.server.rejected_refresh += 1
                                self.reply(400, {})
                                return
                            self.server.counts["refresh"] += 1
                            count = self.server.counts["refresh"]
                            if count > 3:
                                self.reply(400, {})
                                return
                            if count == 3:
                                self.server.refresh_token = "synthetic-consumed-crash"
                                self.server.crash_consumed.set()
                                response = None
                            else:
                                lifetime = 6 if count == 1 else 70
                                expires = int(time.time()) + lifetime
                                self.server.refresh_token = (
                                    "synthetic-rotated-one" if count == 1 else "synthetic-rotated-two")
                                self.server.access_token = base.token(
                                    str(self.server.vector["userID"]), expires, "owned-rotation-" + str(count))
                                self.server.short_expiry = expires
                                response = {"access_token": self.server.access_token,
                                            "expires_in": lifetime, "refresh_token": self.server.refresh_token,
                                            "token_type": "Bearer", "scope": "api offline_access"}
                        if response is None:
                            self.server.stall_release.wait(timeout=15)
                            return
                        self.reply(200, response)
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
            with self.server.lock:
                self.server.counts["sync"] += 1
                authorized = self.headers.get("Authorization") == "Bearer " + self.server.access_token
            if not authorized:
                self.reply(401, {})
                return
            profile = {"id": self.server.vector["userID"], "email": self.server.vector["email"],
                       "emailVerified": True, "organizationsNew": []}
            self.reply(200, {"profile": profile, "folders": [], "ciphers": [], "sends": [],
                             "policiesNew": [], "userDecryption": {}})


    class Server(base.Server):
        def __init__(self) -> None:
            super().__init__(("127.0.0.1", 0))
            self.RequestHandlerClass = Handler
            self.counts = {"prelogin": 0, "login": 0, "refresh": 0, "sync": 0}
            self.short_expiry = None
            self.refresh_attempts = 0
            self.rejected_refresh = 0
            self.crash_consumed = threading.Event()
            self.stall_release = threading.Event()

    return Server


def child_command() -> list[str]:
    return [base.SANDBOX, "-p", base.POLICY, str(base.XCTEST), "-XCTest",
            "BrowserAppTests.NativeBitwardenProcessRestartTests/testOwnedProcessRestartPhase",
            str(BUNDLE)]


def launch(payload: dict[str, object]) -> subprocess.Popen[bytes]:
    environment = base.clean_environment()
    environment["ARCUSIS_PROCESS_RESTART_FIXTURE"] = base64.b64encode(json.dumps(payload).encode()).decode()
    return subprocess.Popen(child_command(), cwd=ROOT, env=environment, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, start_new_session=True)


def finish(child: subprocess.Popen[bytes], timeout: float, phase: str) -> bytes:
    try:
        output, _ = child.communicate(timeout=timeout)
        if child.returncode != 0 or b"Executed 1 test, with 0 failures" not in output:
            lines = sorted(set(re.findall(rb"NativeBitwardenProcessRestartTests\.swift:(\d+)", output)))
            positions = ",".join(value.decode() for value in lines) or "unknown"
            categories = [word for word in ("sessionLocked", "syncFailed", "staleSession",
                          "syncInProgress", "staleAccess", "candidateUnavailable")
                          if word.encode() in output]
            raise RuntimeError("owned XCTest " + phase + " failed at lines " + positions
                               + " categories=" + ",".join(categories))
        return output
    finally:
        cleanup_sandbox_child(child)


def wait_barrier(child: subprocess.Popen[bytes], root: Path, name: str) -> None:
    deadline = time.monotonic() + 30
    while not (root / name).is_file():
        if child.poll() is not None or time.monotonic() >= deadline:
            raise RuntimeError("locked phase did not reach barrier")
        time.sleep(0.02)


def build_and_run() -> None:
    RECEIPT.unlink(missing_ok=True)
    validate_source_manifest(ROOT, SOURCE_MANIFEST, SOURCE_MANIFEST_SHA256)
    load_helper()
    before = fingerprints()
    if SCRATCH.exists() or SCRATCH.is_symlink():
        raise RuntimeError("scratch already exists")
    previous_binary = None  # Fresh scratch has no prebuild binary.
    environment = base.clean_environment()
    environment["ARCUSIS_NATIVE_BITWARDEN_REFRESH_FIXTURE"] = "1"
    base.run_owned_build(["swift", "build", "--build-tests", "--jobs", "2", "--scratch-path", str(SCRATCH)],
                         environment)
    if fingerprints() != before:
        raise RuntimeError("build inputs changed")
    binary = base.digest(BINARY)
    verify_sandbox()
    if fingerprints() != before or base.digest(BINARY) != binary:
        raise RuntimeError("sandbox inputs changed")
    vector, public_key = base.public_vector()
    server = server_class()()
    server.vector = vector
    initial = base.token(str(vector["userID"]), int(time.time()) + 30, "owned-initial")
    server.access_token, server.refresh_token = initial, "synthetic-initial"
    server.login_response = {
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
    server.timeout = 0.1
    stop = threading.Event()
    def serve() -> None:
        while not stop.is_set():
            server.handle_request()
    thread = threading.Thread(target=serve, daemon=True)
    started = False
    child = None
    address = server.server_address
    result = None
    try:
        thread.start()
        started = True
        with tempfile.TemporaryDirectory(prefix="arcusis-restart-", dir=os.environ.get("TMPDIR", "/tmp")) as location:
            try:
                root = Path(location)
                root.chmod(0o700)
                (root / "owned-marker").write_text("arcusis-process-restart-fixture")
                payload = {"directory": location, "endpoint": f"http://127.0.0.1:{address[1]}",
                           "email": vector["email"], "userID": vector["userID"],
                           "currentPassword": vector["currentPassword"], "profileID": str(uuid.uuid4())}
                payload["phase"] = "initial"
                if fingerprints() != before or base.digest(BINARY) != binary:
                    raise RuntimeError("inputs changed before initial child")
                child = launch(payload)
                first_process = child.pid
                finishing = child
                child = None
                finish(finishing, 90, "initial")
                if fingerprints() != before or base.digest(BINARY) != binary:
                    raise RuntimeError("inputs changed after initial child")
                first = json.loads((root / "initial.json").read_text())
                with server.lock:
                    first_counts = dict(server.counts)
                    expiration = server.short_expiry
                if first_counts != {"prelogin": 1, "login": 1, "refresh": 1, "sync": 1} or expiration is None:
                    raise RuntimeError("initial request counts mismatch")
                if first["pid"] != first_process or first["revision"] != 1:
                    raise RuntimeError("initial receipt mismatch")
                deadline = time.monotonic() + 12
                while time.time() <= expiration + 1:
                    if time.monotonic() >= deadline:
                        raise RuntimeError("synthetic expiration wait failed")
                    time.sleep(0.05)
                payload["phase"] = "restore"
                if fingerprints() != before or base.digest(BINARY) != binary:
                    raise RuntimeError("inputs changed before restored child")
                child = launch(payload)
                second_process = child.pid
                wait_barrier(child, root, "locked-ready")
                with server.lock:
                    locked_counts = dict(server.counts)
                if locked_counts != first_counts:
                    raise RuntimeError("locked phase performed network requests")
                (root / "continue").write_text("continue")
                finishing = child
                child = None
                finish(finishing, 90, "restore")
                if fingerprints() != before or base.digest(BINARY) != binary:
                    raise RuntimeError("inputs changed after restored child")
                second = json.loads((root / "restore.json").read_text())
                with server.lock:
                    final_counts = dict(server.counts)
                if (first_process == second_process or second["pid"] != second_process
                        or first["binding"] != second["binding"] or second["revision"] != 2
                        or first["refreshDigest"] == second["refreshDigest"]
                        or final_counts != {"prelogin": 1, "login": 1, "refresh": 2, "sync": 2}
                        or not all(first[k] and second[k] for k in ("locked", "providerCleared", "noPlaintextPassword"))):
                    raise RuntimeError("restored process proof mismatch")
                with server.lock:
                    expiration = server.short_expiry
                deadline = time.monotonic() + 20
                while expiration is not None and time.time() <= expiration - 59:
                    if time.monotonic() >= deadline:
                        raise RuntimeError("crash refresh threshold wait failed")
                    time.sleep(0.05)
                if expiration is None or fingerprints() != before or base.digest(BINARY) != binary:
                    raise RuntimeError("inputs changed before crash child")
                payload["phase"] = "crash"
                child = launch(payload)
                crash_process = child.pid
                deadline = time.monotonic() + 30
                while not server.crash_consumed.wait(timeout=0.05):
                    if child.poll() is not None or time.monotonic() >= deadline:
                        raise RuntimeError("crash refresh not consumed")
                if child.poll() is not None:
                    raise RuntimeError("crash child exited before owned termination")
                cleanup_sandbox_child(child)
                crash_exit = child.returncode
                child = None
                server.stall_release.set()
                if crash_exit == 0 or fingerprints() != before or base.digest(BINARY) != binary:
                    raise RuntimeError("controlled crash or inputs invalid")
                with server.lock:
                    crash_counts = dict(server.counts)
                if crash_counts != {"prelogin": 1, "login": 1, "refresh": 3, "sync": 2}:
                    raise RuntimeError("crash request counts mismatch")
                payload["phase"] = "afterCrash"
                if fingerprints() != before or base.digest(BINARY) != binary:
                    raise RuntimeError("inputs changed before crash recovery child")
                child = launch(payload)
                recovery_process = child.pid
                wait_barrier(child, root, "crash-ready")
                with server.lock:
                    crash_locked_counts = dict(server.counts)
                if crash_locked_counts != crash_counts:
                    raise RuntimeError("interrupted state performed network requests")
                (root / "crash-continue").write_text("continue")
                finishing = child
                child = None
                finish(finishing, 90, "afterCrash")
                if fingerprints() != before or base.digest(BINARY) != binary:
                    raise RuntimeError("inputs changed after crash recovery")
                recovered = json.loads((root / "afterCrash.json").read_text())
                with server.lock:
                    recovery_counts = dict(server.counts)
                    attempts, rejected = server.refresh_attempts, server.rejected_refresh
                if (len({first_process, second_process, crash_process, recovery_process}) != 4
                        or recovered["pid"] != recovery_process or recovered["binding"] != first["binding"]
                        or recovered["revision"] != 0 or recovered["refreshDigest"] == second["refreshDigest"]
                        or recovery_counts != {"prelogin": 2, "login": 2, "refresh": 3, "sync": 3}
                        or attempts != 3 or rejected != 0
                        or not all(recovered[k] for k in ("locked", "providerCleared", "noPlaintextPassword"))):
                    raise RuntimeError("crash recovery replay proof mismatch")
                password = str(vector["currentPassword"]).encode()
                for path in root.rglob("*"):
                    if path.is_file() and password in path.read_bytes():
                        raise RuntimeError("plaintext password persisted")
                result = {"phase1PID": first_process, "phase2PID": second_process,
                          "crashPID": crash_process, "recoveryPID": recovery_process,
                          "sameBinding": True, "distinctPIDs": True, "lockedNoHTTP": True,
                          "rotationPersisted": True, "passwordAbsent": True,
                          "crashExit": crash_exit, "noOldRefreshReplay": True,
                          "initialCounts": first_counts, "lockedCounts": locked_counts,
                          "restoredCounts": final_counts, "crashCounts": crash_counts,
                          "crashLockedCounts": crash_locked_counts, "recoveryCounts": recovery_counts,
                          "refreshAttempts": attempts, "rejectedRefresh": rejected, "binarySHA256": binary,
                          "releaseManifestSHA256": RELEASE_HASH, "fixtureManifestSHA256": DEBUG_HASH,
                          "prebuildBinarySHA256": previous_binary, "inputs": before}
            finally:
                if child is not None:
                    cleanup_sandbox_child(child)
                    child = None
    finally:
        if child is not None:
            cleanup_sandbox_child(child)
        server.stall_release.set()
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
    if result is None:
        raise RuntimeError("no restart proof")
    RECEIPT.parent.mkdir(parents=True, exist_ok=True)
    RECEIPT.write_text(json.dumps(result, sort_keys=True, indent=2) + "\n")
    print("process_restart=passed")
    print("distinct_pids=passed")
    print("locked_no_http=passed")
    print("durable_rotation=passed")
    print("crash_no_replay=passed")
    print("owned_cleanup=passed")
    print("initial_requests=" + json.dumps(result["initialCounts"], sort_keys=True))
    print("restored_requests=" + json.dumps(result["restoredCounts"], sort_keys=True))
    print("crash_recovery_requests=" + json.dumps(result["recoveryCounts"], sort_keys=True))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-manifest", required=True, type=Path)
    parser.add_argument("--source-manifest-sha256", required=True)
    args = parser.parse_args()
    SOURCE_MANIFEST = args.source_manifest
    SOURCE_MANIFEST_SHA256 = args.source_manifest_sha256
    try:
        build_and_run()
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.SubprocessError) as error:
        detail = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        print("process_restart=failed:" + detail, file=sys.stderr)
        raise SystemExit(1)
