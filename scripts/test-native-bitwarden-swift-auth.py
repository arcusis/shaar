#!/usr/bin/env python3
"""Run pinned native Swift auth proof against an owned loopback HTTP fixture."""

from __future__ import annotations

import argparse
import hashlib
import http.client
import http.server
import json
import os
import platform
import re
import shutil
import socket
import socketserver
import subprocess
import sys
import threading
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[1]
PROOF_SHA = "6e2a0a0c74eef6b867341f02feb2be61e4aee7b354389473e7b3964f5b4ae138"
TREE_SHA = "6d4705bc0009aa6a47df290bfd532360de8f054da95cedc6100d61e3b205f77a"
PATCH_SHA = "850c53c73c710772b338bc88760543f66562119984e25bcf0337bfa986842a91"
AUTH_HASH = "Lyry95vlXEJ5FE0EXjeR9zgcsFSU0qGhP9l5X2jwE38="
SOURCE_COMMIT = "5cf919837e83b71c2508bf99344ea57cf5f84e88"
SOURCE_TREE = "9af9432aefeed6796e40e5019ffdc8600f3381e9"
CARGO_LOCK_SHA = "0496b9d35a9c6fd84f79bcc46aa774aa8a86f09eb8c64ba568bc18f4abd0c46a"


class ProofError(Exception):
    pass


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tree_sha(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ProofError("generated input contains symlink")
        if path.is_file():
            digest.update(path.relative_to(root).as_posix().encode() + b"\0")
            digest.update(bytes.fromhex(sha256(path)) + b"\n")
    return digest.hexdigest()


def is_owned_endpoint(value: str) -> bool:
    try:
        parsed = urlsplit(value)
        return (parsed.scheme == "http" and parsed.hostname == "127.0.0.1"
                and parsed.port is not None and parsed.username is None
                and parsed.password is None and not parsed.query and not parsed.fragment
                and parsed.path == "/")
    except ValueError:
        return False


def sanitized_environment(environ: dict[str, str]) -> dict[str, str]:
    return {key: environ[key] for key in ("PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "SDKROOT")
            if key in environ}


def has_label(output: str, label: str) -> bool:
    return label in output.splitlines()


def validate_current_pin() -> None:
    path = ROOT / "ThirdParty/BitwardenAuthSpike/pin.json"
    try:
        if path.is_symlink():
            raise ProofError("accepted SDK pin is symlinked")
        pin = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise ProofError("accepted SDK pin is unavailable or malformed") from None
    expected = {
        "repository": "https://github.com/bitwarden/sdk-internal",
        "sourceCommit": SOURCE_COMMIT, "patchSHA256": PATCH_SHA,
        "rustToolchain": "1.90-aarch64-apple-darwin",
        "target": "aarch64-apple-darwin", "minMacOS": "26.0",
    }
    if (not isinstance(pin, dict) or type(pin.get("schema")) is not int
            or pin.get("schema") != 1 or pin.get("accepted") is not True
            or any(pin.get(key) != value for key, value in expected.items())):
        raise ProofError("current SDK pin no longer accepts these proof inputs")


def validate_receipt(proof_root: Path, source_root: Path) -> tuple[Path, Path, Path]:
    validate_current_pin()
    receipt_path = proof_root / "receipt.json"
    if proof_root.is_symlink() or receipt_path.is_symlink() or not receipt_path.is_file():
        raise ProofError("pinned proof receipt missing or symlinked")
    try:
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise ProofError("pinned proof receipt invalid") from None
    if not isinstance(receipt, dict):
        raise ProofError("proof receipt has invalid shape")
    artifacts = receipt.get("artifacts")
    source = receipt.get("source")
    host = receipt.get("host")
    if not all(isinstance(value, dict) for value in (artifacts, source, host)):
        raise ProofError("proof receipt has invalid nested shape")
    if (type(receipt.get("schema")) is not int or receipt.get("schema") != 1
            or receipt.get("status") != "succeeded"
            or source.get("commit") != SOURCE_COMMIT or source.get("tree") != SOURCE_TREE
            or source.get("cargoLockSHA256") != CARGO_LOCK_SHA
            or receipt.get("patchSHA256") != PATCH_SHA
            or host.get("system") != "Darwin" or host.get("architecture") != "arm64"
            or host.get("target") != "aarch64-apple-darwin"
            or host.get("deploymentTarget") != "26.0"
            or artifacts.get("dylibSHA256") != PROOF_SHA
            or artifacts.get("generatedSwiftTreeSHA256") != TREE_SHA
            or artifacts.get("dylibMinimumMacOS") != "26.0"):
        raise ProofError("proof receipt does not match accepted artifacts")
    try:
        dylib_arg = Path(artifacts["dylibPath"])
        generated_arg = Path(artifacts["generatedSwiftPath"])
        if dylib_arg.is_symlink() or generated_arg.is_symlink():
            raise ProofError("SDK artifact path is symlinked")
        dylib = dylib_arg.resolve(strict=True)
        generated = generated_arg.resolve(strict=True)
        proof_root = proof_root.resolve(strict=True)
        source_root = source_root.resolve(strict=True)
        if not dylib.is_relative_to(proof_root) or not generated.is_relative_to(proof_root):
            raise ProofError("SDK artifacts escape accepted proof root")
    except (KeyError, OSError, TypeError, ValueError):
        raise ProofError("SDK artifact paths are invalid") from None
    if (dylib.is_symlink() or generated.is_symlink() or not dylib.is_file()
            or not generated.is_dir() or sha256(dylib) != PROOF_SHA or tree_sha(generated) != TREE_SHA):
        raise ProofError("SDK inputs differ from accepted receipt")
    patch = ROOT / "ThirdParty/BitwardenAuthSpike/identity-mfa.patch"
    if patch.is_symlink() or not patch.is_file() or sha256(patch) != PATCH_SHA:
        raise ProofError("accepted SDK patch differs from pinned SHA")
    git = subprocess.run(["git", "-C", str(source_root), "rev-parse", "HEAD"],
                         capture_output=True, text=True, timeout=10)
    status = subprocess.run(["git", "-C", str(source_root), "status", "--porcelain=v1", "--untracked-files=no"],
                            capture_output=True, text=True, timeout=10)
    if git.returncode or git.stdout.strip() != SOURCE_COMMIT or status.returncode or status.stdout.strip():
        raise ProofError("source checkout differs from accepted pristine revision")
    support = source_root / "crates/bitwarden-uniffi/swift/Sources/BitwardenSdkSupport/NaiveDateFormatter.swift"
    if support.is_symlink() or not support.is_file():
        raise ProofError("pinned Swift SDK support source missing")
    return dylib, generated, support


def load_success_fixture(source_checkout: Path) -> dict[str, object]:
    source = source_checkout / "crates/bitwarden-auth/src/login/login_via_password/login_via_password_impl.rs"
    if source.is_symlink() or not source.is_file():
        raise ProofError("pinned synthetic SDK response fixture missing")
    text = source.read_text(encoding="utf-8")

    def fixture(name: str) -> str:
        match = re.search(rf'const {name}: &str =\s*"([^"\\]*(?:\\.[^"\\]*)*)";', text)
        if not match:
            raise ProofError("pinned synthetic SDK fixture is incomplete")
        return bytes(match.group(1), "utf-8").decode("unicode_escape")

    private_key = fixture("TEST_PRIVATE_KEY")
    public_key = fixture("TEST_PUBLIC_KEY")
    user_key = fixture("TEST_ENCRYPTED_USER_KEY")
    return {
        "access_token": "synthetic-proof-token", "expires_in": 3600,
        "token_type": "Bearer", "refresh_token": "synthetic-refresh",
        "scope": "api offline_access", "PrivateKey": private_key,
        "AccountKeys": {"publicKeyEncryptionKeyPair": {
            "wrappedPrivateKey": private_key, "publicKey": public_key,
            "Object": "publicKeyEncryptionKeyPair"}, "Object": "privateKeys"},
        "Key": user_key, "MasterPasswordPolicy": {"Object": "masterPasswordPolicy"},
        "ForcePasswordReset": False, "Kdf": 0, "KdfIterations": 600000,
        "KdfMemory": None, "KdfParallelism": None,
        "UserDecryptionOptions": {"HasMasterPassword": True,
            "MasterPasswordUnlock": {"Kdf": {"KdfType": 0, "Iterations": 600000},
                "MasterKeyEncryptedUserKey": user_key, "Salt": "test@example.com"},
            "Object": "userDecryptionOptions"}}


class FixtureHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    state: dict[str, object] = {}

    def log_message(self, _format: str, *_args: object) -> None:
        return

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
            if self.client_address[0] != "127.0.0.1":
                self.reply(403, {})
                return
            if self.headers.get("Transfer-Encoding"):
                self.reply(400, {})
                return
            try:
                raw_length = self.headers.get("Content-Length")
                if raw_length is None or not re.fullmatch(r"[0-9]{1,6}", raw_length):
                    self.reply(400, {})
                    return
                length = int(raw_length)
            except (TypeError, ValueError):
                self.reply(400, {})
                return
            if length < 0 or length > 65536:
                self.reply(413, {})
                return
            body = self.rfile.read(length)
            if len(body) != length:
                self.reply(400, {})
                return
            if self.path == "/identity/accounts/prelogin/password":
                if self.headers.get("Content-Type", "").split(";")[0] != "application/json":
                    self.reply(415, {})
                    return
                try:
                    request = json.loads(body)
                except (UnicodeDecodeError, ValueError):
                    self.state["malformed_requests_rejected"] += 1
                    self.reply(400, {})
                    return
                if not isinstance(request, dict):
                    self.state["malformed_requests_rejected"] += 1
                    self.reply(400, {})
                    return
                self.state["prelogin"] = request.get("email") == "test@example.com"
                self.reply(200, {"kdfSettings": {"kdfType": 0, "iterations": 600000}, "salt": "test@example.com"})
                return
            if self.path != "/identity/connect/token":
                self.reply(404, {})
                return
            try:
                fields = {key: values[0] for key, values in parse_qs(
                    body.decode("ascii"), keep_blank_values=True, strict_parsing=True).items()}
            except (UnicodeDecodeError, ValueError):
                self.state["malformed_requests_rejected"] += 1
                self.reply(400, {})
                return
            # Request values stay in this handler's memory and never enter logs or receipts.
            identity_match = (self.headers.get("Content-Type", "").split(";")[0]
                              == "application/x-www-form-urlencoded"
                              and fields.get("client_id") == "arcusis-browser-synthetic-probe"
                              and fields.get("deviceIdentifier") == "00000000-0000-4000-8000-000000000026"
                              and fields.get("deviceName") == "Synthetic Swift Probe"
                              and fields.get("deviceType") == "21"
                              and fields.get("username") == "test@example.com"
                              and fields.get("password") == AUTH_HASH
                              and fields.get("password") != "test_password")
            self.state["identity"].append(identity_match)
            if self.state.get("mode") == "cancel":
                self.state["cancel_waiting"] = True
                self.state["cancel_event"].wait(15)
                self.reply(503, {})
                return
            token = fields.get("twoFactorToken")
            if token is None:
                if self.state.get("mode") == "normal":
                    self.state["stages"]["mfa_challenge"] = identity_match
                if self.state.get("mode") == "malformed":
                    self.state["malformed_auth_seen"] = True
                    self.reply(400, {"error": "invalid_grant", "error_description": "Two factor required.",
                                     "TwoFactorProviders2": {"99": {}}})
                else:
                    self.reply(400, {"error": "invalid_grant", "error_description": "Two factor required.",
                                     "TwoFactorProviders2": {"0": {}}})
            elif token == "123456":
                self.state["stages"]["mfa_retry_success"] = identity_match
                self.reply(200, self.state["success_fixture"])
            else:
                self.state["stages"]["invalid_mfa"] = identity_match
                self.reply(400, {"error": "invalid_grant", "error_description": "Invalid two-factor code.",
                                 "TwoFactorProviders2": {"0": {}}})
        except (OSError, ValueError, TypeError):
            # Fixed response only; request data and exception details stay private.
            try:
                self.reply(400, {})
            except OSError:
                pass


class FixtureServer(socketserver.ThreadingTCPServer):
    daemon_threads = True

    def handle_error(self, _request: object, _client_address: object) -> None:
        # Unexpected request-handler errors must not print request data in tracebacks.
        return


def write_proof(output: Path, proof: dict[str, object]) -> None:
    output.mkdir(mode=0o700, parents=False)
    path = output / "receipt.json"
    temporary = output / "receipt.json.tmp"
    temporary.write_text(json.dumps(proof, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    temporary.chmod(0o600)
    temporary.replace(path)
    path.chmod(0o600)


def listener_is_closed(server: socketserver.ThreadingTCPServer) -> bool:
    address = server.server_address
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.settimeout(0.5)
        return probe.connect_ex(address) != 0


def run_child(executable: Path, endpoint: str, mode: str, cwd: Path,
              env: dict[str, str], timeout: float) -> tuple[int, str]:
    child = subprocess.run([str(executable), endpoint, mode], cwd=cwd, env=env,
                           timeout=timeout, capture_output=True, text=True)
    return child.returncode, child.stdout


def probe_malformed_mock_request(endpoint: str) -> bool:
    parsed = urlsplit(endpoint)
    connection = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=3)
    try:
        connection.request("POST", "/identity/accounts/prelogin/password",
                           b"not-json-private-sentinel", {"Content-Type": "application/json"})
        response = connection.getresponse()
        body = response.read()
        return (response.status == 400 and b"private-sentinel" not in body
                and body == b"{}")
    except (OSError, http.client.HTTPException):
        return False
    finally:
        connection.close()


def main() -> int:
    parser = argparse.ArgumentParser(description="Run native Swift SDK auth against local mock HTTP.")
    parser.add_argument("--proof-root", required=True, type=Path)
    parser.add_argument("--source", required=True, type=Path, help="pristine pinned SDK checkout")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ProofError("native Swift proof requires arm64 macOS")
    output = args.output.expanduser().absolute()
    if output.exists() or output.is_symlink() or not output.parent.is_dir():
        raise ProofError("output must be a fresh path under an existing parent")
    dylib, generated, support = validate_receipt(
        args.proof_root.expanduser().absolute(), args.source.expanduser().absolute())
    if not (generated / "BitwardenFFI.modulemap").is_file():
        raise ProofError("verified SDK FFI inputs incomplete")
    success_fixture = load_success_fixture(args.source.expanduser().resolve(strict=True))

    work = output.parent / (output.name + ".work")
    if work.exists() or work.is_symlink():
        raise ProofError("private build path already exists")
    work.mkdir(mode=0o700)
    try:
        shutil.copytree(generated, work / "GeneratedSwift")
        shutil.copy2(support, work / "NaiveDateFormatter.swift")
        swift = ROOT / "Tests/NativeBitwardenSwiftAuthProbe/main.swift"
        executable = work / "swift-auth-probe"
        env = sanitized_environment(dict(os.environ))
        env.update({"MACOSX_DEPLOYMENT_TARGET": "26.0", "SWIFT_DETERMINISTIC_HASHING": "1"})
        sources = sorted(str(p) for p in (work / "GeneratedSwift").glob("*.swift"))
        module_maps = sorted(str(p) for p in (work / "GeneratedSwift").glob("*.modulemap"))
        module_flags = [item for path in module_maps for item in ("-Xcc", f"-fmodule-map-file={path}")]
        support_object = work / "BitwardenSdkSupport.o"
        support_module = work / "BitwardenSdkSupport.swiftmodule"
        support_build = subprocess.run(
            ["swiftc", "-parse-as-library", "-target", "arm64-apple-macosx26.0", "-module-name", "BitwardenSdkSupport",
             "-emit-module", "-emit-module-path", str(support_module), "-emit-object", "-o",
             str(support_object), str(support)], cwd=work, env=env, timeout=60,
            capture_output=True, text=True)
        if support_build.returncode:
            raise ProofError("pinned Swift support module build failed")
        command = ["swiftc", "-target", "arm64-apple-macosx26.0", "-I", str(work), "-I", str(work / "GeneratedSwift"),
                   *module_flags, "-L", str(dylib.parent), "-lbitwarden_uniffi", "-Xlinker", "-rpath", "-Xlinker",
                   str(dylib.parent), *sources, str(support_object), str(swift), "-o", str(executable)]
        result = subprocess.run(command, cwd=work, env=env, timeout=180, capture_output=True, text=True)
        if result.returncode:
            raise ProofError("Swift SDK executable build failed")
        minos = subprocess.run(["vtool", "-show-build", str(executable)], env=env, timeout=15,
                               capture_output=True, text=True)
        dylib_minos = subprocess.run(["vtool", "-show-build", str(dylib)], env=env, timeout=15,
                                     capture_output=True, text=True)
        if (minos.returncode or "minos 26.0" not in minos.stdout
                or dylib_minos.returncode or "minos 26.0" not in dylib_minos.stdout):
            raise ProofError("SDK dylib and Swift executable must target macOS 26.0")

        FixtureHandler.state = {"prelogin": False, "identity": [], "mode": "normal",
                                "cancel_waiting": False, "cancel_event": threading.Event(),
                                "malformed_auth_seen": False, "malformed_requests_rejected": 0,
                                "success_fixture": success_fixture,
                                "stages": {"mfa_challenge": False, "mfa_retry_success": False,
                                           "invalid_mfa": False, "malformed_challenge": False}}
        server = FixtureServer(("127.0.0.1", 0), FixtureHandler)
        server.timeout = 2
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        endpoint = f"http://127.0.0.1:{server.server_address[1]}/"
        if not is_owned_endpoint(endpoint):
            raise ProofError("runner-created mock endpoint failed loopback validation")
        malformed_mock_ok = probe_malformed_mock_request(endpoint)
        normal_code, normal_stdout = run_child(executable, endpoint, "normal", work, env, 60)
        normal_ok = (normal_code == 0 and has_label(normal_stdout, "swift_auth=passed")
                     and all(has_label(normal_stdout, label) for label in
                             ("mfa_challenge=passed", "mfa_retry_success=passed", "invalid_mfa=passed")))
        FixtureHandler.state["mode"] = "malformed"
        malformed_code, malformed_stdout = run_child(executable, endpoint, "malformed", work, env, 30)
        malformed_ok = (malformed_code == 0 and has_label(malformed_stdout, "swift_malformed_challenge=rejected")
                        and bool(FixtureHandler.state["malformed_auth_seen"]))
        FixtureHandler.state["stages"]["malformed_challenge"] = malformed_ok

        # Attempt native Task cancellation, then independently bound the child lifetime.
        FixtureHandler.state["mode"] = "cancel"
        child = subprocess.Popen([str(executable), endpoint, "cancel"], cwd=work, env=env,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            child.wait(timeout=2)
            parent_terminated = False
        except subprocess.TimeoutExpired:
            child.terminate()
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=2)
            parent_terminated = child.poll() is not None
        # Read only the fixed marker; never persist or expose captured SDK output.
        cancellation_stdout, _ = child.communicate(timeout=2)
        child_exit_observed = child.poll() is not None
        cancellation_requested = (bool(FixtureHandler.state["cancel_waiting"])
                                  and has_label(cancellation_stdout, "swift_cancellation=requested"))

        identity_ok = bool(FixtureHandler.state["identity"]) and all(FixtureHandler.state["identity"])
        stages = FixtureHandler.state["stages"]
        stages["mfa_retry_success"] = stages["mfa_retry_success"] and normal_ok
        stages["invalid_mfa"] = stages["invalid_mfa"] and normal_ok
        stages["prelogin"] = bool(FixtureHandler.state["prelogin"])
        stages["malformed_mock_request_rejected"] = malformed_mock_ok
        FixtureHandler.state["cancel_event"].set()
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)
        listener_thread_stopped = not thread.is_alive()
        listener_closed = server.socket.fileno() == -1
        listener_refused_reconnect = listener_is_closed(server)
        cleanup_ok = (parent_terminated and child_exit_observed and cancellation_requested
                      and listener_thread_stopped and listener_closed and listener_refused_reconnect)
        stages["bounded_parent_child_cleanup"] = cleanup_ok
        auth_passed = normal_ok and malformed_ok and malformed_mock_ok and identity_ok and all(
            stages[name] for name in ("prelogin", "mfa_challenge", "mfa_retry_success", "invalid_mfa", "malformed_challenge"))
        proof = {
            "schema": 1, "scope": "native_swift_ffi_http_mock", "stages": stages,
            "auth_passed": auth_passed, "integration_ready": False,
            "native_task_cancellation_supported": False,
            "cancellation_requested": cancellation_requested,
            "bounded_parent_child_terminated": parent_terminated,
            "child_exit_observed": child_exit_observed,
            "listener_thread_stopped": listener_thread_stopped,
            "listener_closed": listener_closed,
            "listener_refused_reconnect": listener_refused_reconnect,
            "malformed_mock_requests_rejected": malformed_mock_ok,
            "posted_identity_match": identity_ok, "sdk_password_hash_match": identity_ok,
            "device_type_match": identity_ok,
            "source_commit": SOURCE_COMMIT, "patch_sha256": PATCH_SHA,
            "dylib_sha256": PROOF_SHA, "generated_swift_tree_sha256": TREE_SHA,
            "swift_probe_source_sha256": sha256(swift), "executed_swift_sha256": sha256(executable),
            "host_system": platform.platform(), "host_architecture": platform.machine(),
            "dylib_minimum_macos": "26.0", "swift_executable_minimum_macos": "26.0",
            "status": "diagnostic_complete" if auth_passed and cleanup_ok else "diagnostic_incomplete"}
        write_proof(output, proof)
        print("swift_auth=passed" if auth_passed else "swift_auth=failed")
        print("scope=native_swift_ffi_http_mock")
        print("integration_ready=false")
        print("native_task_cancellation_supported=false")
        print(f"bounded_parent_child_cleanup={'passed' if cleanup_ok else 'failed'}")
        return 0 if auth_passed and cleanup_ok else 1
    except subprocess.TimeoutExpired:
        raise ProofError("Swift auth process exceeded fixed timeout") from None
    finally:
        # Also handles build and unexpected diagnostic failures before server setup.
        if "server" in locals():
            FixtureHandler.state["cancel_event"].set()
            server.shutdown()
            server.server_close()
            if "thread" in locals():
                thread.join(timeout=3)
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ProofError as exc:
        print(f"swift_auth=preflight_failed reason={exc}", file=sys.stderr)
        raise SystemExit(2)
