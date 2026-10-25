#!/usr/bin/env python3
"""Build and run generated Swift SDK sync against an owned loopback mock."""
from __future__ import annotations

import argparse
import hashlib
import http.server
import importlib.util
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
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
SOURCE_COMMIT = "5cf919837e83b71c2508bf99344ea57cf5f84e88"
SOURCE_TREE = "9af9432aefeed6796e40e5019ffdc8600f3381e9"
CARGO_LOCK_SHA = "0496b9d35a9c6fd84f79bcc46aa774aa8a86f09eb8c64ba568bc18f4abd0c46a"
AUTH_SHA = "850c53c73c710772b338bc88760543f66562119984e25bcf0337bfa986842a91"
TARGET = "aarch64-apple-darwin"
TOOLCHAIN = "1.90-aarch64-apple-darwin"

class ProofError(Exception):
    pass

def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

def tree_sha(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        if path.is_symlink(): raise ProofError("generated input contains symlink")
        if path.is_file():
            digest.update(path.relative_to(root).as_posix().encode() + b"\0")
            digest.update(bytes.fromhex(sha(path)) + b"\n")
    return digest.hexdigest()

def worktree_sha256(root: Path) -> str:
    digest = hashlib.sha256()
    for current, directories, files in os.walk(root, followlinks=False):
        current_path = Path(current)
        directories[:] = sorted(name for name in directories if name != ".git")
        for name in directories:
            if (current_path / name).is_symlink(): raise ProofError("patched source contains symlink")
        for name in sorted(files):
            path = current_path / name
            if path.is_symlink(): raise ProofError("patched source contains symlink")
            relative = path.relative_to(root).as_posix()
            digest.update(relative.encode() + b"\0")
            digest.update(hashlib.sha256(path.read_bytes()).digest() + b"\n")
    return digest.hexdigest()

def validate_pin(pin_path: Path, patch_path: Path, *, candidate: bool = False) -> dict[str, object]:
    if pin_path.is_symlink() or patch_path.is_symlink() or not pin_path.is_file() or not patch_path.is_file():
        raise ProofError("candidate pin or sync patch missing or symlinked")
    try: pin = json.loads(pin_path.read_text(encoding="utf-8"))
    except (OSError, ValueError): raise ProofError("candidate pin invalid") from None
    expected = {
        "repository": "https://github.com/bitwarden/sdk-internal",
        "sourceCommit": SOURCE_COMMIT,
        "sourceTreeSHA256": SOURCE_TREE,
        "authPatchFile": "../BitwardenAuthSpike/identity-mfa.patch",
        "authPatchSHA256": AUTH_SHA,
        "patchFile": "sync.patch",
        "rustToolchain": TOOLCHAIN,
        "target": TARGET,
        "minMacOS": "26.0",
    }
    if (not isinstance(pin, dict) or type(pin.get("schema")) is not int or pin.get("schema") != 1
            or type(pin.get("accepted")) is not bool or pin.get("accepted") is not (not candidate)
            or any(pin.get(key) != value for key, value in expected.items())
            or type(pin.get("patchBytes")) is not int or pin.get("patchBytes") != patch_path.stat().st_size
            or type(pin.get("changedFiles")) is not int or pin.get("changedFiles") != 5
            or pin.get("patchSHA256") != sha(patch_path)
            or type(pin.get("integration_ready")) is not bool or pin.get("integration_ready") is not False):
        raise ProofError("candidate pin differs from reviewed source, patch, target, or status")
    return pin

def load_auth_runner():
    spec = importlib.util.spec_from_file_location("sync_auth_runner", ROOT / "scripts/test-native-bitwarden-swift-auth.py")
    if spec is None or spec.loader is None: raise ProofError("accepted auth runner unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

def sdk_vector(source_root: Path) -> dict[str, object]:
    """Read the pinned SDK public V1 crypto fixture into process memory."""
    path = source_root / "crates/bitwarden-core/src/client/test_accounts.rs"
    if path.is_symlink() or not path.is_file(): raise ProofError("pinned public crypto fixture missing")
    text = path.read_text(encoding="utf-8")
    section = text.split("pub fn test_bitwarden_com_account() -> TestAccount {", 1)
    if len(section) != 2: raise ProofError("pinned public crypto fixture unavailable")
    section = section[1].split("/// ### V2 `test@bitwarden.com`", 1)[0]
    def capture(pattern: str) -> str:
        match = re.search(pattern, section, re.DOTALL)
        if not match: raise ProofError("pinned public crypto fixture incomplete")
        return match.group(1)
    return {
        "email": capture(r'let email = "([^"\\]+)";'),
        "userID": capture(r'user_id: Some\(UserId::new\(uuid::uuid!\("([^"\\]+)"\)\)\)'),
        "currentPassword": capture(r'password: "([^"\\]+)"\.to_owned\(\)'),
        "privateKey": capture(r'private_key: "([^"\\]+)"\.parse::<EncString>\(\)'),
        "wrappedUserKey": capture(r'master_key_wrapped_user_key: "([^"\\]+)"\.parse\(\)'),
        "iterations": int(capture(r'iterations: ([0-9_]+)\.try_into\(\)')),
    }

def owned_endpoint(value: str) -> bool:
    try:
        p = urlsplit(value)
        return p.scheme == "http" and p.hostname == "127.0.0.1" and p.port is not None and not p.username and not p.password and not p.query and not p.fragment and p.path == "/"
    except ValueError:
        return False

def listener_is_closed(address: tuple[str, int]) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.settimeout(0.5)
        return probe.connect_ex(address) != 0

def write_receipt(output: Path, value: dict[str, object]) -> None:
    path = output / "receipt.json"
    temp = output / "receipt.json.tmp"
    temp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    temp.chmod(0o600)
    temp.replace(path)
    path.chmod(0o600)

class MockHandler(http.server.BaseHTTPRequestHandler):
    state: dict[str, object] = {}
    protocol_version = "HTTP/1.1"
    def log_message(self, *_args: object) -> None: return
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
    def do_GET(self) -> None:
        try:
            if self.client_address[0] != "127.0.0.1" or not self.path.startswith("/api/sync"):
                self.reply(404, {})
                return
            expected = self.state["token"]
            matched = self.headers.get("Authorization") == f"Bearer {expected}"
            self.state["requests"].append((self.path, matched))
            request_count = len(self.state["requests"])
            if not matched or request_count == 2:
                self.reply(401, {})
            elif request_count == 3:
                self.reply(200, {"profile": {"id": self.state["user_id"]}, "folders": [], "ciphers": [{"type": "malformed"}], "sends": [], "policiesNew": [], "userDecryption": {}})
            else:
                self.reply(200, self.state["success"])
        except (OSError, ValueError, TypeError):
            try: self.reply(400, {})
            except OSError: pass

class OwnedServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = False
    daemon_threads = True
    def handle_error(self, *_args: object) -> None: return

def parse_test_count(output: str) -> int:
    return sum(int(m.group(1)) for m in re.finditer(r"(\d+) passed;", output))

def tests_passed(return_code: int, output: str) -> bool:
    return return_code == 0 and parse_test_count(output) > 0

def prepared_fixture(output: bytes) -> dict[str, object]:
    text = output.decode("utf-8", errors="replace")
    decoder = json.JSONDecoder()
    for offset, character in enumerate(text):
        if character != "{": continue
        try: value, _end = decoder.raw_decode(text[offset:])
        except ValueError: continue
        if isinstance(value, dict) and isinstance(value.get("cipher"), dict): return value
    raise ProofError("SDK crypto preparation returned no encrypted cipher")

def main() -> int:
    parser = argparse.ArgumentParser(description="Run actual native Swift SDK sync against loopback mock HTTP.")
    parser.add_argument("--candidate", action="store_true", help="explicitly build unaccepted proposal")
    parser.add_argument("--proof-root", required=True, type=Path, help="accepted auth SDK proof root")
    parser.add_argument("--source", required=True, type=Path, help="pristine pinned SDK checkout")
    parser.add_argument("--output", required=True, type=Path, help="fresh private output directory")
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64": raise ProofError("native proof requires arm64 macOS")
    pin_path = ROOT / "ThirdParty/BitwardenSyncSpike/pin.json"
    patch = ROOT / "ThirdParty/BitwardenSyncSpike/sync.patch"
    source = args.source.expanduser().absolute()
    output = args.output.expanduser().absolute()
    if source.is_symlink() or not source.is_dir(): raise ProofError("SDK source missing or symlinked")
    if output.exists() or output.is_symlink() or not output.parent.is_dir(): raise ProofError("output must be fresh under existing parent")
    pin = validate_pin(pin_path, patch, candidate=args.candidate)
    auth = load_auth_runner()
    auth.validate_receipt(args.proof_root.expanduser().absolute(), source.resolve(strict=True))
    vector = sdk_vector(source.resolve(strict=True))
    git = subprocess.run(["git", "-C", str(source), "rev-parse", "HEAD"], capture_output=True, text=True, timeout=10)
    status = subprocess.run(["git", "-C", str(source), "status", "--porcelain=v1", "--untracked-files=no"], capture_output=True, text=True, timeout=10)
    if git.returncode or git.stdout.strip() != SOURCE_COMMIT or status.returncode or status.stdout.strip(): raise ProofError("SDK checkout is not pristine pinned source")
    if sha(source / "Cargo.lock") != CARGO_LOCK_SHA: raise ProofError("SDK lockfile hash differs from accepted source")
    env = {k: os.environ[k] for k in ("PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "SDKROOT", "RUSTUP_HOME", "CARGO_HOME") if k in os.environ}
    env.update({"RUSTUP_TOOLCHAIN": TOOLCHAIN, "MACOSX_DEPLOYMENT_TARGET": "26.0", "CARGO_NET_OFFLINE": "true", "CARGO_BUILD_JOBS": "2", "CARGO_TERM_COLOR": "never", "SWIFT_DETERMINISTIC_HASHING": "1", "RUSTFLAGS": "-C link-arg=-Wl,-application_extension -C link-arg=-mmacosx-version-min=26.0 --cfg bitwarden_ensure_non_commercial"})
    rustc = subprocess.run(["rustc", "--version"], env=env, capture_output=True, text=True, timeout=10)
    cargo = subprocess.run(["cargo", "--version"], env=env, capture_output=True, text=True, timeout=10)
    targets = subprocess.run(["rustup", "target", "list", "--installed"], env=env, capture_output=True, text=True, timeout=10)
    if rustc.returncode or not rustc.stdout.startswith("rustc 1.90.") or cargo.returncode or not cargo.stdout.startswith("cargo 1.90."):
        raise ProofError("pinned Rust 1.90 toolchain unavailable; no install attempted")
    if targets.returncode or TARGET not in targets.stdout.splitlines(): raise ProofError("required Rust target missing; no install attempted")
    output.mkdir(mode=0o700)
    receipt: dict[str, object] = {"schema": 1, "status": "running", "scope": "native_swift_ffi_loopback_sync", "integration_ready": False, "accepted": pin["accepted"], "candidate": args.candidate, "sourceCommit": SOURCE_COMMIT, "sourceTreeSHA256": SOURCE_TREE, "patchedSourceSHA256": None, "candidateCargoLockSHA256": None, "authPatchSHA256": AUTH_SHA, "syncPatchSHA256": sha(patch), "stageLabels": {}, "commands": [], "testCount": 0}
    checkout = output / "sdk-internal"
    target_dir = output / "cargo-target"
    work = output / "work"
    server = None
    thread = None
    child = None
    def step(name: str, command: list[str], cwd: Path, step_env: dict[str, str] = env) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(command, cwd=cwd, env=step_env, capture_output=True, text=True, timeout=1200)
        receipt["commands"].append({"name": name, "argv": command, "exitCode": result.returncode})
        return result
    try:
        clone = step("clone", ["git", "clone", "--local", "--no-hardlinks", "--no-checkout", str(source), str(checkout)], ROOT)
        if clone.returncode: raise ProofError("private SDK clone failed")
        commands = [
            ("checkout", ["git", "-C", str(checkout), "checkout", "--detach", SOURCE_COMMIT]),
            ("auth_patch_check", ["git", "-C", str(checkout), "apply", "--check", "--whitespace=error", str(ROOT / "ThirdParty/BitwardenAuthSpike/identity-mfa.patch")]),
            ("auth_patch", ["git", "-C", str(checkout), "apply", "--whitespace=error", str(ROOT / "ThirdParty/BitwardenAuthSpike/identity-mfa.patch")]),
            ("sync_patch_check", ["git", "-C", str(checkout), "apply", "--check", "--whitespace=error", str(patch)]),
            ("sync_patch", ["git", "-C", str(checkout), "apply", "--whitespace=error", str(patch)]),
            ("diff_check", ["git", "-C", str(checkout), "diff", "--check"]),
        ]
        for name, command in commands:
            result = step(name, command, ROOT, env)
            if result.returncode: raise ProofError(f"private SDK {name} failed")
        expected_files = {
            "Cargo.lock", "crates/bitwarden-pm/Cargo.toml", "crates/bitwarden-pm/src/lib.rs",
            "crates/bitwarden-uniffi/src/lib.rs", "crates/bitwarden-uniffi/src/sync.rs",
        }
        patch_scope = step("patch_file_scope", ["git", "apply", "--numstat", str(patch)], ROOT, env)
        patch_files = {line.split("\t")[-1] for line in patch_scope.stdout.splitlines() if line.strip()}
        if patch_scope.returncode or patch_files != expected_files or len(patch_files) != pin["changedFiles"]:
            raise ProofError("sync patch changed-file scope differs from pin")
        receipt["patchedSourceSHA256"] = worktree_sha256(checkout)
        receipt["candidateCargoLockSHA256"] = sha(checkout / "Cargo.lock")
        build_env = dict(env, CARGO_TARGET_DIR=str(target_dir))
        common = ["--offline", "--locked", "--manifest-path", str(checkout / "Cargo.toml"), "--target", TARGET]
        tests = step("bitwarden_sync_tests", ["cargo", "test", *common, "--package", "bitwarden-sync"], checkout, build_env)
        passed = parse_test_count(tests.stdout + "\n" + tests.stderr)
        receipt["testCount"] = passed
        if not tests_passed(tests.returncode, tests.stdout + "\n" + tests.stderr): raise ProofError("focused bitwarden-sync tests failed or count missing")
        build = step("bitwarden_uniffi_build", ["cargo", "build", *common, "--package", "bitwarden-uniffi"], checkout, build_env)
        if build.returncode: raise ProofError("native UniFFI SDK build failed")
        dylib = target_dir / TARGET / "debug/libbitwarden_uniffi.dylib"
        if not dylib.is_file() or dylib.is_symlink(): raise ProofError("native SDK dylib missing")
        dylib_minos = step("dylib_min_os", ["vtool", "-show-build", str(dylib)], ROOT, env)
        if dylib_minos.returncode or not re.search(r"minos\s+26\.0(?:\s|$)", dylib_minos.stdout):
            raise ProofError("native SDK dylib minimum macOS differs from pin")
        generated = output / "GeneratedSwift"
        generate = step("swift_bindgen", ["cargo", "run", "--offline", "--locked", "--package", "uniffi-bindgen", "--", "generate", str(dylib), "--language", "swift", "--no-format", "--out-dir", str(generated)], checkout, build_env)
        if generate.returncode: raise ProofError("generated Swift bindings failed")
        if not dylib.is_file() or not list(generated.glob("*.swift")): raise ProofError("native SDK artifacts missing")
        support = checkout / "crates/bitwarden-uniffi/swift/Sources/BitwardenSdkSupport/NaiveDateFormatter.swift"
        work.mkdir(mode=0o700)
        swift_dir = ROOT / "Tests/NativeBitwardenSyncProbe"
        sources = sorted(str(p) for p in generated.glob("*.swift"))
        maps = sorted(str(p) for p in generated.glob("*.modulemap"))
        module_flags = [arg for p in maps for arg in ("-Xcc", f"-fmodule-map-file={p}")]
        swift_env = dict(env, MACOSX_DEPLOYMENT_TARGET="26.0")
        support_obj, support_module = work / "BitwardenSdkSupport.o", work / "BitwardenSdkSupport.swiftmodule"
        support_build = subprocess.run(["swiftc", "-parse-as-library", "-target", "arm64-apple-macosx26.0", "-module-name", "BitwardenSdkSupport", "-emit-module", "-emit-module-path", str(support_module), "-emit-object", "-o", str(support_obj), str(support)], cwd=work, env=swift_env, capture_output=True, text=True, timeout=90)
        receipt["commands"].append({"name": "swift_support", "argv": ["swiftc", "support"], "exitCode": support_build.returncode})
        if support_build.returncode: raise ProofError("Swift SDK support compile failed")
        executable = work / "native-sync-probe"
        compile_cmd = ["swiftc", "-target", "arm64-apple-macosx26.0", "-I", str(work), "-I", str(generated), *module_flags, "-L", str(dylib.parent), "-lbitwarden_uniffi", "-Xlinker", "-rpath", "-Xlinker", str(dylib.parent), *sources, str(support_obj), str(swift_dir / "Fixtures.swift"), str(swift_dir / "main.swift"), "-o", str(executable)]
        compiled = subprocess.run(compile_cmd, cwd=work, env=swift_env, capture_output=True, text=True, timeout=240)
        receipt["commands"].append({"name": "swift_probe_compile", "argv": ["swiftc", "generated FFI + owned probe"], "exitCode": compiled.returncode})
        if compiled.returncode: raise ProofError("generated Swift proof compile failed")
        fixture = {key: vector[key] for key in ("email", "userID", "currentPassword", "privateKey", "wrappedUserKey", "iterations")}
        fixture_bytes = json.dumps(fixture, separators=(",", ":")).encode()
        prep = subprocess.run([str(executable), "prepare"], cwd=work, env=swift_env, input=fixture_bytes, capture_output=True, timeout=90)
        if prep.returncode: raise ProofError("SDK public crypto fixture preparation failed")
        prepared = prepared_fixture(prep.stdout)
        success = {"profile": {"id": vector["userID"], "email": vector["email"], "emailVerified": True}, "folders": [], "ciphers": [prepared["cipher"]], "sends": [], "policiesNew": [], "userDecryption": {}}
        MockHandler.state = {"token": "synthetic-sync-token", "user_id": vector["userID"], "success": success, "mode": "success", "requests": []}
        server = OwnedServer(("127.0.0.1", 0), MockHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        endpoint = f"http://127.0.0.1:{server.server_address[1]}/"
        if not owned_endpoint(endpoint): raise ProofError("owned loopback endpoint validation failed")
        child = subprocess.Popen([str(executable), endpoint, "sync"], cwd=work, env=swift_env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            stdout, _stderr = child.communicate(fixture_bytes, timeout=90)
        except subprocess.TimeoutExpired:
            child.terminate()
            try: child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait(timeout=2)
            raise ProofError("Swift sync child exceeded fixed timeout") from None
        child_exit_observed = child.poll() is not None
        output_text = stdout.decode("utf-8", errors="replace")
        server_address = server.server_address
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)
        listener_thread_stopped = not thread.is_alive()
        listener_closed = server.socket.fileno() == -1
        listener_refused_reconnect = listener_is_closed(server_address)
        cleanup_ok = child_exit_observed and listener_thread_stopped and listener_closed and listener_refused_reconnect
        server = None
        thread = None
        labels = {name: f"{name}=passed" in output_text.splitlines() for name in ("fetched_cipher_decrypted", "host_token_sync_request", "unauthenticated_snapshot_preserved", "malformed_snapshot_preserved", "independent_client_unchanged", "snapshot_publication")}
        labels["snapshot_publication"] = "snapshot_publication=success_only" in output_text.splitlines()
        requests = MockHandler.state["requests"]
        request_ok = len(requests) == 3 and all(path.startswith("/api/sync") and authorized for path, authorized in requests)
        labels["mock_observed_three_host_token_requests"] = request_ok
        labels["bounded_child_listener_cleanup"] = cleanup_ok
        receipt["stageLabels"] = labels
        receipt["childExitObserved"] = child_exit_observed
        receipt["listenerThreadStopped"] = listener_thread_stopped
        receipt["listenerClosed"] = listener_closed
        receipt["listenerRefusedReconnect"] = listener_refused_reconnect
        executable_minos = step("executable_min_os", ["vtool", "-show-build", str(executable)], ROOT, env)
        if executable_minos.returncode or not re.search(r"minos\s+26\.0(?:\s|$)", executable_minos.stdout):
            raise ProofError("Swift executable minimum macOS differs from pin")
        if child.returncode or not all(labels.values()): raise ProofError("Swift sync acceptance stages failed")
        receipt["artifacts"] = {"sourceTreeSHA256": SOURCE_TREE, "patchedSourceSHA256": receipt["patchedSourceSHA256"], "candidateCargoLockSHA256": receipt["candidateCargoLockSHA256"], "authPatchSHA256": AUTH_SHA, "syncPatchSHA256": sha(patch), "dylibSHA256": sha(dylib), "generatedSwiftTreeSHA256": tree_sha(generated), "swiftMainSourceSHA256": sha(swift_dir / "main.swift"), "swiftFixturesSourceSHA256": sha(swift_dir / "Fixtures.swift"), "executableSHA256": sha(executable), "dylibMinimumMacOS": "26.0", "executableMinimumMacOS": "26.0"}
        receipt["status"] = "succeeded"
        print("native_sync=passed")
        print("scope=native_swift_ffi_loopback_sync")
        print("integration_ready=false")
        for name, passed in labels.items(): print(f"{name}={'passed' if passed else 'failed'}")
        return 0
    except subprocess.TimeoutExpired:
        receipt["status"] = "failed"
        receipt["failure"] = "bounded proof command timed out"
        print("native_sync=failed reason=bounded_timeout", file=sys.stderr)
        return 1
    except ProofError as exc:
        receipt["status"] = "failed"
        receipt["failure"] = str(exc)
        print(f"native_sync=failed reason={exc}", file=sys.stderr)
        return 1
    finally:
        if child is not None and child.poll() is None:
            child.terminate()
            try: child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill(); child.wait(timeout=2)
        if server is not None:
            server.shutdown(); server.server_close()
        if thread is not None: thread.join(timeout=3)
        if output.exists() and "receipt" in locals(): write_receipt(output, receipt)
        if work.exists(): shutil.rmtree(work, ignore_errors=True)

if __name__ == "__main__":
    try: raise SystemExit(main())
    except (ProofError, OSError, ValueError) as exc:
        print(f"native_sync=preflight_failed reason={exc}", file=sys.stderr)
        raise SystemExit(2)
