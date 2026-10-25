#!/usr/bin/env python3
"""Run pinned Swift password login, crypto initialization, and cipher proof."""

from __future__ import annotations

import argparse
import hashlib
import http.server
import importlib.util
import json
import os
import platform
import re
import secrets
import shutil
import socket
import socketserver
import subprocess
import sys
import threading
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[1]
AUTH_RUNNER_PATH = ROOT / "scripts/test-native-bitwarden-swift-auth.py"
_SPEC = importlib.util.spec_from_file_location("accepted_auth_runner", AUTH_RUNNER_PATH)
if _SPEC is None or _SPEC.loader is None:
    raise RuntimeError("accepted auth proof runner unavailable")
AUTH_RUNNER = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(AUTH_RUNNER)
SOURCE_COMMIT = AUTH_RUNNER.SOURCE_COMMIT
PATCH_SHA = AUTH_RUNNER.PATCH_SHA
PROOF_SHA = AUTH_RUNNER.PROOF_SHA
TREE_SHA = AUTH_RUNNER.TREE_SHA


class ProofError(Exception):
    pass


def is_owned_endpoint(value: str) -> bool:
    try:
        parsed = urlsplit(value)
        return (parsed.scheme == "http" and parsed.hostname == "127.0.0.1"
                and parsed.port is not None and parsed.username is None
                and parsed.password is None and not parsed.query and not parsed.fragment
                and parsed.path == "/")
    except ValueError:
        return False


def sdk_vector(source_root: Path) -> dict[str, object]:
    """Read public V1 test-account inputs from exact pristine SDK source."""
    path = source_root / "crates/bitwarden-core/src/client/test_accounts.rs"
    if path.is_symlink() or not path.is_file():
        raise ProofError("pinned SDK public crypto vector missing")
    text = path.read_text(encoding="utf-8")
    section = text.split("pub fn test_bitwarden_com_account() -> TestAccount {", 1)
    if len(section) != 2:
        raise ProofError("pinned SDK public crypto vector unavailable")
    section = section[1].split("/// ### V2 `test@bitwarden.com`", 1)[0]

    def capture(pattern: str) -> str:
        match = re.search(pattern, section, re.DOTALL)
        if not match:
            raise ProofError("pinned SDK public crypto vector incomplete")
        return match.group(1)

    return {
        "email": capture(r'let email = "([^"\\]+)";'),
        "userID": capture(r'user_id: Some\(UserId::new\(uuid::uuid!\("([^"\\]+)"\)\)\)'),
        "currentPassword": capture(r'password: "([^"\\]+)"\.to_owned\(\)'),
        "privateKey": capture(r'private_key: "([^"\\]+)"\.parse::<EncString>\(\)'),
        "wrappedUserKey": capture(r'master_key_wrapped_user_key: "([^"\\]+)"\.parse\(\)'),
        "iterations": int(capture(r'iterations: ([0-9_]+)\.try_into\(\)')),
    }


def write_private_receipt(output: Path, receipt: dict[str, object]) -> None:
    output.mkdir(mode=0o700, parents=False)
    path = output / "receipt.json"
    temporary = output / "receipt.json.tmp"
    temporary.write_text(json.dumps(receipt, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    temporary.chmod(0o600)
    temporary.replace(path)
    path.chmod(0o600)


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
            if self.client_address[0] != "127.0.0.1" or self.headers.get("Transfer-Encoding"):
                self.reply(400, {})
                return
            length_text = self.headers.get("Content-Length", "")
            if not re.fullmatch(r"[0-9]{1,6}", length_text):
                self.reply(400, {})
                return
            length = int(length_text)
            if length > 65536:
                self.reply(413, {})
                return
            body = self.rfile.read(length)
            if len(body) != length:
                self.reply(400, {})
                return
            if self.path == "/identity/accounts/prelogin/password":
                request = json.loads(body)
                matched = isinstance(request, dict) and request.get("email") == self.state["email"]
                self.state["prelogin_seen"] = True
                self.state["prelogin"] = bool(matched)
                self.reply(200, {"kdfSettings": {"kdfType": 0,
                             "iterations": self.state["iterations"]}, "salt": self.state["email"]})
                return
            if self.path != "/identity/connect/token":
                self.reply(404, {})
                return
            fields = {key: values[0] for key, values in parse_qs(
                body.decode("ascii"), keep_blank_values=True, strict_parsing=True).items()}
            matched = (
                self.headers.get("Content-Type", "").split(";")[0] == "application/x-www-form-urlencoded"
                and fields.get("client_id") == "arcusis-browser-synthetic-probe"
                and fields.get("deviceIdentifier") == "00000000-0000-4000-8000-000000000026"
                and fields.get("deviceName") == "Synthetic Swift Probe"
                and fields.get("deviceType") == "21"
                and fields.get("username") == self.state["email"]
                and fields.get("password") == self.state["passwordHash"]
            )
            self.state["identity_seen"] = True
            self.state["identity_match"] = bool(matched)
            if not matched:
                self.reply(400, {"error": "invalid_grant"})
                return
            self.reply(200, self.state["success_fixture"])
        except (OSError, ValueError, TypeError, UnicodeDecodeError):
            try:
                self.reply(400, {})
            except OSError:
                pass


class FixtureServer(socketserver.ThreadingTCPServer):
    daemon_threads = True

    def handle_error(self, _request: object, _client_address: object) -> None:
        return


def run_child(executable: Path, endpoint: str, mode: str, cwd: Path,
              env: dict[str, str], payload: bytes, timeout: float = 90) -> tuple[int, str]:
    result = subprocess.run([str(executable), endpoint, mode], cwd=cwd, env=env,
                            input=payload, timeout=timeout, capture_output=True)
    return result.returncode, result.stdout.decode("utf-8", errors="replace")


def prepared_fixture(stdout: str) -> dict[str, object]:
    decoder = json.JSONDecoder()
    for offset, character in enumerate(stdout):
        if character != "{":
            continue
        try:
            value, _end = decoder.raw_decode(stdout[offset:])
        except ValueError:
            continue
        if isinstance(value, dict) and all(key in value for key in ("email", "passwordHash", "newKey")):
            return value
    raise ProofError("SDK crypto vector preparation returned no typed result")


def failure_stage(*outputs: str) -> str | None:
    allowed = {
        "prelogin_sdk_error", "prelogin_mismatch", "password_login_sdk_error",
        "login_response_mismatch", "user_crypto_install_error", "cipher_encrypt_error",
        "cipher_decrypt_error", "cipher_roundtrip_mismatch", "crypto_fixture_incomplete",
        "input_decode_error", "endpoint_invalid",
    }
    for output in outputs:
        for line in output.splitlines():
            if line.startswith("session_stage=") and line.removeprefix("session_stage=") in allowed:
                return line.removeprefix("session_stage=")
    return None


def compile_probe(work: Path, generated: Path, dylib: Path, support: Path,
                  env: dict[str, str]) -> Path:
    swift_dir = ROOT / "Tests/NativeBitwardenSessionProbe"
    sources = sorted(str(path) for path in generated.glob("*.swift"))
    module_maps = sorted(str(path) for path in generated.glob("*.modulemap"))
    module_flags = [item for path in module_maps for item in ("-Xcc", f"-fmodule-map-file={path}")]
    support_object = work / "BitwardenSdkSupport.o"
    support_module = work / "BitwardenSdkSupport.swiftmodule"
    support_build = subprocess.run(
        ["swiftc", "-parse-as-library", "-target", "arm64-apple-macosx26.0",
         "-module-name", "BitwardenSdkSupport", "-emit-module", "-emit-module-path",
         str(support_module), "-emit-object", "-o", str(support_object), str(support)],
        cwd=work, env=env, timeout=60, capture_output=True)
    if support_build.returncode:
        raise ProofError("pinned Swift support module build failed")
    executable = work / "native-session-probe"
    result = subprocess.run(
        ["swiftc", "-target", "arm64-apple-macosx26.0", "-I", str(work),
         "-I", str(generated), *module_flags, "-L", str(dylib.parent), "-lbitwarden_uniffi",
         "-Xlinker", "-rpath", "-Xlinker", str(dylib.parent), *sources,
         str(support_object), str(swift_dir / "Fixtures.swift"), str(swift_dir / "main.swift"),
         "-o", str(executable)],
        cwd=work, env=env, timeout=180, capture_output=True)
    if result.returncode:
        diagnostic_text = result.stderr.decode("utf-8", errors="replace")
        safe_diagnostics: list[str] = []
        for line in diagnostic_text.splitlines():
            if "error:" not in line:
                continue
            message = line.split("error:", 1)[1].strip()
            conform = re.search(r"does not conform to protocol '([A-Za-z0-9_]+)'", message)
            missing = re.search(r"cannot find '([A-Za-z0-9_]+)' in scope", message)
            member = re.search(r"value of type '([A-Za-z0-9_]+)' has no member '([A-Za-z0-9_]+)'", message)
            if conform:
                safe_diagnostics.append(f"conformance:{conform.group(1)}")
            elif missing:
                safe_diagnostics.append(f"missing-symbol:{missing.group(1)}")
            elif member:
                safe_diagnostics.append(f"missing-member:{member.group(1)}.{member.group(2)}")
            elif "cannot convert value of type" in message:
                safe_diagnostics.append("type-mismatch")
            elif "extra argument" in message or "missing argument" in message:
                safe_diagnostics.append("argument-mismatch")
            elif "ambiguous" in message:
                safe_diagnostics.append("ambiguous-reference")
            else:
                safe_diagnostics.append("swift-typecheck-error")
        suffix = ",".join(dict.fromkeys(safe_diagnostics[:8]))
        reason = "Swift session executable build failed"
        if suffix:
            reason += f" ({suffix})"
        raise ProofError(reason)
    return executable


def run(args: argparse.Namespace) -> int:
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ProofError("native Swift proof requires arm64 macOS")
    output = args.output.expanduser().absolute()
    if output.exists() or output.is_symlink() or not output.parent.is_dir():
        raise ProofError("output must be a fresh path under an existing parent")
    source = args.source.expanduser().absolute()
    dylib, generated, support = AUTH_RUNNER.validate_receipt(
        args.proof_root.expanduser().absolute(), source)
    if not (generated / "BitwardenFFI.modulemap").is_file():
        raise ProofError("verified SDK FFI inputs incomplete")
    vector = sdk_vector(source.resolve(strict=True))
    vector["newPassword"] = secrets.token_urlsafe(24)
    work = output.parent / (output.name + ".work")
    if work.exists() or work.is_symlink():
        raise ProofError("private build path already exists")
    work.mkdir(mode=0o700)
    server = None
    thread = None
    try:
        shutil.copytree(generated, work / "GeneratedSwift")
        shutil.copy2(support, work / "NaiveDateFormatter.swift")
        env = {key: os.environ[key] for key in
               ("PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "SDKROOT") if key in os.environ}
        env.update({"MACOSX_DEPLOYMENT_TARGET": "26.0", "SWIFT_DETERMINISTIC_HASHING": "1"})
        executable = compile_probe(work, work / "GeneratedSwift", dylib, support, env)
        for path in (executable, dylib):
            minos = subprocess.run(["vtool", "-show-build", str(path)], env=env,
                                   timeout=15, capture_output=True, text=True)
            if minos.returncode or "minos 26.0" not in minos.stdout:
                raise ProofError("SDK dylib and Swift executable must target macOS 26.0")

        vector_bytes = json.dumps(vector, separators=(",", ":")).encode()
        prep_code, prep_stdout = run_child(executable, "", "prepare", work, env, vector_bytes, 180)
        if prep_code:
            safe_markers = {"crypto_vector_initialize=failed", "sdk_password_update=failed",
                            "native_session=failed"}
            marker = next((line for line in prep_stdout.splitlines() if line in safe_markers), "")
            reason = "SDK crypto vector preparation failed"
            if marker:
                reason += f" ({marker})"
            raise ProofError(reason)
        prepared = prepared_fixture(prep_stdout)
        if (not isinstance(prepared, dict) or prepared.get("email") != vector["email"]
                or not isinstance(prepared.get("passwordHash"), str)
                or not isinstance(prepared.get("newKey"), str)):
            raise ProofError("SDK crypto vector preparation returned invalid shape")
        login_fixture = {
            "email": vector["email"], "userID": vector["userID"],
            "newPassword": vector["newPassword"],
            "privateKey": prepared["privateKey"], "iterations": vector["iterations"],
            "passwordHash": prepared["passwordHash"], "newKey": prepared["newKey"],
        }
        success_fixture = {
            "access_token": "synthetic-session-token", "expires_in": 3600,
            "token_type": "Bearer", "refresh_token": "synthetic-refresh-token",
            "scope": "api offline_access", "PrivateKey": prepared["privateKey"],
            "AccountKeys": {"publicKeyEncryptionKeyPair": {
                "wrappedPrivateKey": prepared["privateKey"],
                "publicKey": "synthetic-public-key", "Object": "publicKeyEncryptionKeyPair"},
                "Object": "privateKeys"},
            "Key": prepared["newKey"], "Kdf": 0,
            "KdfIterations": vector["iterations"], "KdfMemory": None, "KdfParallelism": None,
            "ForcePasswordReset": False,
            "UserDecryptionOptions": {"HasMasterPassword": True,
                "MasterPasswordUnlock": {"Kdf": {"KdfType": 0,
                    "Iterations": vector["iterations"]},
                    "MasterKeyEncryptedUserKey": prepared["newKey"],
                    "Salt": vector["email"]}, "Object": "userDecryptionOptions"},
        }
        FixtureHandler.state = {
            "email": vector["email"], "iterations": vector["iterations"],
            "passwordHash": prepared["passwordHash"], "success_fixture": success_fixture,
            "prelogin": False, "prelogin_seen": False,
            "identity_match": False, "identity_seen": False,
        }
        server = FixtureServer(("127.0.0.1", 0), FixtureHandler)
        server.timeout = 2
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        endpoint = f"http://127.0.0.1:{server.server_address[1]}/"
        if not is_owned_endpoint(endpoint):
            raise ProofError("runner-created mock endpoint failed loopback validation")
        login_payload = json.dumps(login_fixture, separators=(",", ":")).encode()
        login_code, login_stdout = run_child(executable, endpoint, "login", work, env, login_payload)
        login_ok = (login_code == 0 and all(
            label in login_stdout.splitlines() for label in
            ("swift_login=passed", "user_key_installation=passed", "cipher_roundtrip=passed",
             "token_publication=owned-provider", "independent_client=locked",
             "independent_context=preserved")))
        invalid_code, invalid_stdout = run_child(executable, endpoint, "invalid", work, env, login_payload)
        invalid_ok = (invalid_code == 0 and all(
            label in invalid_stdout.splitlines() for label in
            ("invalid_crypto_setup=rejected", "token_publication=none",
             "candidate_key=unavailable", "independent_client=locked",
             "independent_context=preserved")))
        stages = {
            "sdk_password_hash_match": bool(FixtureHandler.state["identity_match"]),
            "prelogin_request_seen": bool(FixtureHandler.state["prelogin_seen"]),
            "identity_request_seen": bool(FixtureHandler.state["identity_seen"]),
            "prelogin_kdf_and_salt_match": bool(FixtureHandler.state["prelogin"]),
            "swift_login_and_user_key_installation": login_ok,
            "typed_invalid_setup_rejected_without_token": invalid_ok,
            "invalid_candidate_key_unavailable": invalid_ok,
            "cipher_roundtrip": login_ok,
            "independent_client_stays_locked": login_ok and invalid_ok,
            "independent_context_preserved": login_ok and invalid_ok,
        }
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)
        listener_stopped = not thread.is_alive() and server.socket.fileno() == -1
        stages["mock_listener_cleanup"] = listener_stopped
        failed_stage = failure_stage(login_stdout, invalid_stdout)
        if failed_stage is not None:
            stages["swift_failure_stage"] = failed_stage
        accepted = all(stages.values())
        receipt = {
            "schema": 1, "scope": "local_native_password_key_cipher_proof",
            "stages": stages, "integration_ready": False,
            "source_commit": SOURCE_COMMIT, "patch_sha256": PATCH_SHA,
            "dylib_sha256": PROOF_SHA, "generated_swift_tree_sha256": TREE_SHA,
            "probe_source_sha256": {
                "main": hashlib.sha256((ROOT / "Tests/NativeBitwardenSessionProbe/main.swift").read_bytes()).hexdigest(),
                "fixtures": hashlib.sha256((ROOT / "Tests/NativeBitwardenSessionProbe/Fixtures.swift").read_bytes()).hexdigest(),
            },
            "host_system": platform.platform(), "host_architecture": platform.machine(),
            "minimum_macos": "26.0", "status": "proof_complete" if accepted else "proof_incomplete",
        }
        write_private_receipt(output, receipt)
        print("native_session=" + ("passed" if accepted else "failed"))
        print("scope=local_native_password_key_cipher_proof")
        print("integration_ready=false")
        return 0 if accepted else 1
    except subprocess.TimeoutExpired:
        raise ProofError("native session child exceeded fixed timeout") from None
    finally:
        if server is not None:
            server.shutdown()
            server.server_close()
            if thread is not None:
                thread.join(timeout=3)
        shutil.rmtree(work, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Run SDK login-to-key proof with owned loopback mock.")
    parser.add_argument("--proof-root", required=True, type=Path)
    parser.add_argument("--source", required=True, type=Path, help="pristine pinned SDK checkout")
    parser.add_argument("--output", required=True, type=Path)
    return run(parser.parse_args())


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ProofError as exc:
        print(f"native_session=preflight_failed reason={exc}", file=sys.stderr)
        raise SystemExit(2)
