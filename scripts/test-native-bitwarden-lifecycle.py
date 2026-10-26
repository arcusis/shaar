#!/usr/bin/env python3
"""Build one pinned auth/clear/sync SDK and prove native vault lifecycle."""

from __future__ import annotations

import argparse
import base64
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
import tempfile
import threading
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[1]
PIN_PATH = ROOT / "ThirdParty/BitwardenLifecycleProbe/pin.json"
SOURCE_COMMIT = "5cf919837e83b71c2508bf99344ea57cf5f84e88"
SOURCE_TREE = "9af9432aefeed6796e40e5019ffdc8600f3381e9"
SOURCE_LOCK_SHA = "0496b9d35a9c6fd84f79bcc46aa774aa8a86f09eb8c64ba568bc18f4abd0c46a"
CANDIDATE_LOCK_SHA = "ec67cefc4ea30f8aa473f4181cd32204287429a42463e8eb9d9df59979f0892b"
PATCH_SHAS = {
    "auth": "850c53c73c710772b338bc88760543f66562119984e25bcf0337bfa986842a91",
    "clear": "f62fb617c615570d1a4280fd459af8b081caa758ad50fe4f57ebd7b34bdc2bf4",
    "sync": "26c6c57921ade94d4b6bed4b1627bf879ee6665fe23b5462b4b10a79633c7533",
}
TARGET = "aarch64-apple-darwin"
TOOLCHAIN = "1.90-aarch64-apple-darwin"
CHANGED_PATHS = {
    "Cargo.lock",
    "crates/bitwarden-auth/src/login/api/request/login_api_request.rs",
    "crates/bitwarden-auth/src/login/api/response/login_error_api_response.rs",
    "crates/bitwarden-auth/src/login/api/response/mod.rs",
    "crates/bitwarden-auth/src/login/api/response/two_factor_required_api_response.rs",
    "crates/bitwarden-auth/src/login/api/send_login_request.rs",
    "crates/bitwarden-auth/src/login/login_client.rs",
    "crates/bitwarden-auth/src/login/login_via_password/login_via_password_impl.rs",
    "crates/bitwarden-auth/src/login/login_via_password/mod.rs",
    "crates/bitwarden-auth/src/login/login_via_password/password_login_api_request.rs",
    "crates/bitwarden-auth/src/login/login_via_password/password_login_error.rs",
    "crates/bitwarden-auth/src/login/login_via_password/password_login_request.rs",
    "crates/bitwarden-auth/src/login/models/login_request.rs",
    "crates/bitwarden-auth/src/login/models/login_response.rs",
    "crates/bitwarden-auth/src/login/models/mod.rs",
    "crates/bitwarden-auth/src/login/models/two_factor.rs",
    "crates/bitwarden-core/src/key_management/crypto_client.rs",
    "crates/bitwarden-pm/Cargo.toml",
    "crates/bitwarden-pm/src/lib.rs",
    "crates/bitwarden-uniffi/src/crypto.rs",
    "crates/bitwarden-uniffi/src/lib.rs",
    "crates/bitwarden-uniffi/src/sync.rs",
}
REQUIRED_STAGES = {
    "sdk_password_login", "sdk_user_crypto_initialized", "gate_store_token_commit",
    "credential_store_readback", "sdk_sync_fetched_cipher", "sdk_cipher_decrypted",
    "lock_sdk_shared_keys_cleared", "lock_host_bridge_cleared",
    "retained_key_read_rejected", "retained_cipher_decrypt_rejected",
    "independent_profile_still_usable", "explicit_unlock_reinitialized",
    "fetched_cipher_decrypted_after_unlock", "disabled_late_commit_rejected",
    "disabled_candidate_keys_unusable", "rebound_late_commit_rejected",
    "rebound_candidate_keys_unusable", "auth_failure_no_publication",
    "disabled_candidate_record_removed", "rebound_candidate_record_removed",
    "denied_store_candidate_login_initialized", "denied_store_no_token_publication",
    "denied_store_candidate_keys_unusable", "denied_store_independent_client_preserved",
    "denied_store_candidate_record_absent", "disconnect_owned_record_removed",
    "credential_records_removed",
    "independent_record_preserved",
    "synthetic_https_identity_only", "mock_sdk_token_observed",
}
PREPARED_OUTPUT_MARKER = b"BITWARDEN_LIFECYCLE_PREPARED_V1:"
LIFECYCLE_STAGE_MARKER = "BITWARDEN_LIFECYCLE_STAGE_V1:"
LIFECYCLE_COMPLETION_MARKER = "BITWARDEN_LIFECYCLE_COMPLETE_V1"
MAX_NATIVE_OUTPUT_BYTES = 4 * 1024 * 1024


class ProofError(Exception):
    pass


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tree_sha(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ProofError("generated Swift input contains symlink")
        if path.is_file():
            digest.update(path.relative_to(root).as_posix().encode() + b"\0")
            digest.update(bytes.fromhex(sha256(path)) + b"\n")
    return digest.hexdigest()


def worktree_sha(root: Path) -> str:
    digest = hashlib.sha256()
    for current, directories, files in os.walk(root, followlinks=False):
        base = Path(current)
        directories[:] = sorted(name for name in directories if name != ".git")
        for name in directories:
            if (base / name).is_symlink():
                raise ProofError("SDK candidate contains symlink")
        for name in sorted(files):
            path = base / name
            if path.is_symlink():
                raise ProofError("SDK candidate contains symlink")
            digest.update(path.relative_to(root).as_posix().encode() + b"\0")
            digest.update(hashlib.sha256(path.read_bytes()).digest() + b"\n")
    return digest.hexdigest()


def patch_paths(path: Path) -> set[str]:
    text = path.read_text(encoding="utf-8")
    result = set(re.findall(r"^diff --git a/(.*?) b/", text, re.M))
    result.update(re.findall(r"^--- a/(.+)$", text, re.M))
    result.update(re.findall(r"^\+\+\+ b/(.+)$", text, re.M))
    result.discard("/dev/null")
    return result


def load_auth_module():
    spec = importlib.util.spec_from_file_location(
        "lifecycle_auth_runner", ROOT / "scripts/test-native-bitwarden-swift-auth.py")
    if spec is None or spec.loader is None:
        raise ProofError("accepted auth proof helper unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read_pin(candidate: bool) -> tuple[dict[str, object], dict[str, Path]]:
    patch_paths_by_name = {
        "auth": ROOT / "ThirdParty/BitwardenAuthSpike/identity-mfa.patch",
        "clear": ROOT / "ThirdParty/BitwardenKeyClearSpike/clear-crypto-keys.patch",
        "sync": ROOT / "ThirdParty/BitwardenSyncSpike/sync.patch",
    }
    try:
        if PIN_PATH.is_symlink():
            raise ProofError("lifecycle pin is symlinked")
        pin = json.loads(PIN_PATH.read_text(encoding="utf-8"))
        if not isinstance(pin, dict):
            raise ProofError("lifecycle pin shape invalid")
        for patch in patch_paths_by_name.values():
            if patch.is_symlink() or not patch.is_file():
                raise ProofError("accepted SDK patch missing or symlinked")
    except (OSError, ValueError):
        raise ProofError("lifecycle pin or SDK patch unavailable") from None
    expected = {
        "schema": 1, "accepted": not candidate, "integration_ready": False,
        "repository": "https://github.com/bitwarden/sdk-internal",
        "sourceCommit": SOURCE_COMMIT, "sourceTreeSHA256": SOURCE_TREE,
        "sourceCargoLockSHA256": SOURCE_LOCK_SHA,
        "candidateCargoLockSHA256": CANDIDATE_LOCK_SHA,
        "changedFiles": 22, "rustToolchain": TOOLCHAIN, "target": TARGET,
        "minMacOS": "26.0", "credentialAuthorityMode": "synthetic_https_identity",
        "tlsAuthorityBindingAccepted": False,
    }
    if (type(pin.get("schema")) is not int or type(pin.get("accepted")) is not bool
            or type(pin.get("integration_ready")) is not bool
            or type(pin.get("changedFiles")) is not int
            or type(pin.get("tlsAuthorityBindingAccepted")) is not bool
            or any(pin.get(key) != value for key, value in expected.items())):
        raise ProofError("lifecycle pin differs from accepted SDK contract")
    if type(pin.get("changedFiles")) is not int or pin["changedFiles"] != 22:
        raise ProofError("lifecycle pin changed-path count invalid")
    for name, path in patch_paths_by_name.items():
        if sha256(path) != PATCH_SHAS[name] or pin.get(f"{name}PatchSHA256") != PATCH_SHAS[name]:
            raise ProofError("SDK patch digest differs from lifecycle pin")
    union = set().union(*(patch_paths(path) for path in patch_paths_by_name.values()))
    if union != CHANGED_PATHS or len(union) != 22:
        raise ProofError("SDK patch path set differs from exact 22-path contract")
    pin_changed = pin.get("changedPaths")
    if (not isinstance(pin_changed, list) or any(not isinstance(item, str) for item in pin_changed)
            or set(pin_changed) != CHANGED_PATHS or len(pin_changed) != 22):
        raise ProofError("lifecycle pin changed paths differ from patches")
    if pin["accepted"] is False and not candidate:
        raise ProofError("candidate pin requires explicit --candidate")
    if pin["accepted"] is True and candidate:
        raise ProofError("--candidate requires an unaccepted pin")
    validate_component_pins()
    return pin, patch_paths_by_name


def validate_component_pins() -> None:
    expected = {
        ROOT / "ThirdParty/BitwardenAuthSpike/pin.json":
            ("identity-mfa.patch", PATCH_SHAS["auth"], 15),
        ROOT / "ThirdParty/BitwardenKeyClearSpike/pin.json":
            ("clear-crypto-keys.patch", PATCH_SHAS["clear"], 2),
        ROOT / "ThirdParty/BitwardenSyncSpike/pin.json":
            ("sync.patch", PATCH_SHAS["sync"], 5),
    }
    for path, (patch_name, patch_hash, count) in expected.items():
        if path.is_symlink():
            raise ProofError("component pin symlinked")
        try:
            pin = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            raise ProofError("component pin unavailable") from None
        if (not isinstance(pin, dict) or type(pin.get("schema")) is not int
                or pin.get("schema") != 1 or type(pin.get("accepted")) is not bool
                or pin.get("accepted") is not True
                or pin.get("repository") != "https://github.com/bitwarden/sdk-internal"
                or pin.get("sourceCommit") != SOURCE_COMMIT
                or pin.get("rustToolchain") != TOOLCHAIN or pin.get("target") != TARGET
                or pin.get("minMacOS") != "26.0"):
            raise ProofError("component pin no longer accepts required patch")
        if patch_name == "identity-mfa.patch":
            digest = pin.get("patchSHA256")
        elif patch_name == "clear-crypto-keys.patch":
            digest = pin.get("patchSHA256")
        else:
            digest = pin.get("patchSHA256")
        if digest != patch_hash:
            raise ProofError("component pin patch hash mismatch")
        if type(pin.get("patchBytes")) is not int or pin["patchBytes"] != (
                path.parent / patch_name).stat().st_size:
            raise ProofError("component pin patch length mismatch")
        if type(pin.get("changedFiles")) is not int or pin["changedFiles"] != count:
            raise ProofError("component pin patch file count mismatch")
        if patch_name == "sync.patch" and pin.get("integration_ready") is not False:
            raise ProofError("sync component readiness pin changed")


def sdk_vector(source: Path) -> dict[str, object]:
    path = source / "crates/bitwarden-core/src/client/test_accounts.rs"
    if path.is_symlink() or not path.is_file():
        raise ProofError("pinned public SDK fixture missing")
    content = path.read_text(encoding="utf-8")
    start = content.find("pub fn test_bitwarden_com_account() -> TestAccount {")
    stop = content.find("/// ### V2 `test@bitwarden.com`", start)
    if start < 0 or stop < 0:
        raise ProofError("pinned public SDK fixture shape mismatch")
    section = content[start:stop]

    def capture(pattern: str) -> str:
        match = re.search(pattern, section, re.S)
        if not match:
            raise ProofError("pinned public SDK fixture incomplete")
        return match.group(1)

    try:
        value = {
            "email": capture(r'let email = "([^"\\]+)";'),
            "userID": capture(r'user_id: Some\(UserId::new\(uuid::uuid!\("([^"\\]+)"\)\)\)'),
            "currentPassword": capture(r'password: "([^"\\]+)"\.to_owned\(\)'),
            "privateKey": capture(r'private_key: "([^"\\]+)"\.parse::<EncString>\(\)'),
            "wrappedUserKey": capture(r'master_key_wrapped_user_key: "([^"\\]+)"\.parse\(\)'),
            "iterations": int(capture(r'iterations: ([0-9_]+)\.try_into\(\)')),
        }
    except (ValueError, TypeError):
        raise ProofError("pinned public SDK fixture invalid") from None
    if (not isinstance(value["iterations"], int) or value["iterations"] <= 0
            or not all(isinstance(value[key], str) and value[key]
                       for key in ("email", "userID", "currentPassword", "privateKey", "wrappedUserKey"))):
        raise ProofError("pinned public SDK fixture values invalid")
    return value


def source_digests() -> list[dict[str, str]]:
    files = [ROOT / "Sources/BrowserCore/PasswordAuthenticationGate.swift",
             ROOT / "Sources/BrowserCore/PasswordCredentialStore.swift"]
    result = []
    for path in files:
        if path.is_symlink() or not path.is_file():
            raise ProofError("required BrowserCore source missing or symlinked")
        result.append({"path": path.relative_to(ROOT).as_posix(), "sha256": sha256(path)})
    return result


def run_command(argv: list[str], *, cwd: Path, env: dict[str, str], timeout: int,
                label: str, receipt: dict[str, object], check: bool = True) -> subprocess.CompletedProcess[str]:
    try:
        result = subprocess.run(argv, cwd=cwd, env=env, capture_output=True,
                                text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        receipt["commands"].append({"name": label, "result": "timeout"})
        raise ProofError(f"{label} timed out") from None
    receipt["commands"].append({
        "name": label, "exitCode": result.returncode,
        "result": "passed" if result.returncode == 0 else "failed",
    })
    if label == "swift_native_probe_build" and result.returncode:
        diagnostics: list[dict[str, object]] = []
        for line in (result.stdout + "\n" + result.stderr).splitlines():
            match = re.search(r"([^/\\]+\.swift):(\d+):(\d+): (error|warning):", line)
            if match:
                diagnostics.append({"file": match.group(1), "line": int(match.group(2)),
                                    "column": int(match.group(3)),
                                    "severity": match.group(4)})
        receipt["commands"][-1]["diagnostics"] = diagnostics[:30]
    if check and result.returncode:
        raise ProofError(f"{label} failed")
    return result


def verify_source(source: Path, env: dict[str, str], receipt: dict[str, object]) -> tuple[Path, dict[str, object]]:
    if source.is_symlink() or not source.is_dir():
        raise ProofError("pinned SDK source unavailable or symlinked")
    source = source.resolve(strict=True)
    head = run_command(["git", "-C", str(source), "rev-parse", "HEAD"], cwd=ROOT,
                       env=env, timeout=15, label="source_commit", receipt=receipt)
    status = run_command(["git", "-C", str(source), "status", "--porcelain=v1", "--untracked-files=no"],
                         cwd=ROOT, env=env, timeout=15, label="source_cleanliness", receipt=receipt)
    tree = run_command(["git", "-C", str(source), "rev-parse", "HEAD^{tree}"], cwd=ROOT,
                       env=env, timeout=15, label="source_tree", receipt=receipt)
    if (head.stdout.strip() != SOURCE_COMMIT or status.stdout.strip()
            or tree.stdout.strip() != SOURCE_TREE):
        raise ProofError("SDK source differs from pristine pinned checkout")
    lock = source / "Cargo.lock"
    if lock.is_symlink() or not lock.is_file() or sha256(lock) != SOURCE_LOCK_SHA:
        raise ProofError("SDK source Cargo.lock differs from source pin")
    vector = sdk_vector(source)
    auth = load_auth_module()
    login_fixture = auth.load_success_fixture(source)
    vector["loginPublicKey"] = login_fixture["AccountKeys"]["publicKeyEncryptionKeyPair"]["publicKey"]
    vector["loginPrivateKey"] = login_fixture["PrivateKey"]
    for relative in (
        "crates/bitwarden-auth/src/login/login_via_password/login_via_password_impl.rs",
        "crates/bitwarden-pm/src/lib.rs",
        "crates/bitwarden-core/src/key_management/crypto_client.rs",
    ):
        candidate = source / relative
        if candidate.is_symlink() or not candidate.is_file():
            raise ProofError("pinned SDK lifecycle API source missing")
    return source, vector


def check_toolchain(env: dict[str, str], receipt: dict[str, object]) -> None:
    rustc = run_command(["rustc", "--version"], cwd=ROOT, env=env, timeout=15,
                        label="rustc_version", receipt=receipt)
    cargo = run_command(["cargo", "--version"], cwd=ROOT, env=env, timeout=15,
                        label="cargo_version", receipt=receipt)
    targets = run_command(["rustup", "target", "list", "--installed"], cwd=ROOT,
                          env=env, timeout=20, label="installed_targets", receipt=receipt)
    if (not rustc.stdout.startswith("rustc 1.90.") or not cargo.stdout.startswith("cargo 1.90.")
            or TARGET not in targets.stdout.splitlines()):
        raise ProofError("pinned Rust 1.90 target unavailable; no install attempted")


def parse_test_count(output: str) -> tuple[int, int, int]:
    matches = re.findall(r"test result: (ok|FAILED)\. (\d+) passed; (\d+) failed;", output)
    passed = sum(int(total) for status, total, _failed in matches if status == "ok")
    failed = sum(int(count) for _status, _total, count in matches)
    return passed, failed, len(matches)


def validate_rust_regression(
    returncode: int, counts: tuple[int, int, int], label: str
) -> tuple[int, int, int]:
    passed, failed, suites = counts
    if returncode or passed < 1 or failed or suites < 1:
        raise ProofError(f"{label} failed or reported zero tests")
    return passed, failed, suites


def validate_stage_output(output: str, mock_state: dict[str, object]) -> dict[str, bool]:
    labels: dict[str, list[str]] = {}
    if len(output.encode("utf-8")) > MAX_NATIVE_OUTPUT_BYTES:
        return {name: False for name in sorted(REQUIRED_STAGES)}
    lines = output.splitlines()
    if lines.count(LIFECYCLE_COMPLETION_MARKER) != 1:
        return {name: False for name in sorted(REQUIRED_STAGES)}
    for line in output.splitlines():
        if not line.startswith(LIFECYCLE_STAGE_MARKER):
            continue
        payload = line[len(LIFECYCLE_STAGE_MARKER):]
        if "=" not in payload:
            continue
        name, value = payload.split("=", 1)
        if name in REQUIRED_STAGES:
            labels.setdefault(name, []).append(value)
    result = {name: labels.get(name) == ["passed"] for name in sorted(REQUIRED_STAGES)}
    result["mock_sdk_token_observed"] = (
        result.get("mock_sdk_token_observed", False)
        and mock_state.get("validSyncAuthorization") is True
        and mock_state.get("syncRequests") == 1
    )
    late_response_observed = (
        mock_state.get("lateResponsesHeld") == 3
        and mock_state.get("lateResponsesReleased") == 3
    )
    result["disabled_late_commit_rejected"] = (
        result.get("disabled_late_commit_rejected", False) and late_response_observed)
    result["rebound_late_commit_rejected"] = (
        result.get("rebound_late_commit_rejected", False) and late_response_observed)
    return result


def observed_mock_counts(state: dict[str, object]) -> dict[str, int]:
    return {
        "prelogin": int(state.get("preloginRequests", 0)),
        "validLogin": int(state.get("validLoginRequests", 0)),
        "rejectedLogin": int(state.get("rejectedLoginRequests", 0)),
        "sync": int(state.get("syncRequests", 0)),
        "held": int(state.get("lateResponsesHeld", 0)),
        "released": int(state.get("lateResponsesReleased", 0)),
        "unexpected": int(state.get("unexpectedRequests", 0)),
    }


EXPECTED_MOCK_COUNTS = {
    "prelogin": 5, "validLogin": 4, "rejectedLogin": 1, "sync": 1,
    "held": 3, "released": 3, "unexpected": 0,
}


def write_receipt(output: Path, receipt: dict[str, object]) -> None:
    def reject_sensitive_fields(value: object) -> None:
        if isinstance(value, dict):
            forbidden = {"password", "passwordhash", "accesstoken", "refreshtoken",
                         "newkey", "privatekey", "wrappeduserkey", "cipher",
                         "ciphertext", "plaintext", "request", "requestbody", "secret"}
            if any(str(key).replace("_", "").lower() in forbidden for key in value):
                raise ProofError("receipt contains prohibited field")
            for child in value.values():
                reject_sensitive_fields(child)
        elif isinstance(value, list):
            for child in value:
                reject_sensitive_fields(child)

    reject_sensitive_fields(receipt)
    if output.is_symlink() or not output.is_dir() or output.stat().st_mode & 0o777 != 0o700:
        raise ProofError("receipt root lost private mode")
    path, temporary = output / "receipt.json", output / "receipt.json.tmp"
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(receipt, stream, sort_keys=True, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    path.chmod(0o600)


def create_private_root(path: Path) -> None:
    path.mkdir(mode=0o700)
    path.chmod(0o700)
    if path.stat().st_mode & 0o777 != 0o700:
        raise ProofError("private root mode is not 0700")


def remove_private_work(path: Path) -> bool:
    if path.exists():
        shutil.rmtree(path)
    return not path.exists()


def preserve_build_artifacts(work: Path, output: Path, receipt: dict[str, object]) -> None:
    target_dir = work / "cargo-target"
    dylib = target_dir / TARGET / "debug/libbitwarden_uniffi.dylib"
    generated = work / "GeneratedSwift"
    if not dylib.is_file() or dylib.is_symlink() or not generated.is_dir() or generated.is_symlink():
        return
    generated_hash = tree_sha(generated)
    destination = output / "artifacts"
    if destination.exists() or destination.is_symlink():
        if destination.is_symlink() or not destination.is_dir():
            raise ProofError("artifact destination is not a private directory")
        copied_dylib = destination / "libbitwarden_uniffi.dylib"
        copied_generated = destination / "GeneratedSwift"
        if (destination.stat().st_mode & 0o777 != 0o700
                or copied_dylib.is_symlink() or not copied_dylib.is_file()
                or copied_generated.is_symlink() or not copied_generated.is_dir()
                or sha256(copied_dylib) != sha256(dylib)
                or tree_sha(copied_generated) != generated_hash):
            raise ProofError("preserved SDK artifacts differ from current private build")
        return
    destination.mkdir(mode=0o700)
    destination.chmod(0o700)
    copied_dylib = destination / "libbitwarden_uniffi.dylib"
    shutil.copyfile(dylib, copied_dylib)
    copied_dylib.chmod(0o600)
    copied_generated = destination / "GeneratedSwift"
    shutil.copytree(generated, copied_generated, symlinks=False)
    for current, directories, files in os.walk(copied_generated):
        Path(current).chmod(0o700)
        for name in files:
            path = Path(current) / name
            if path.is_symlink() or not path.is_file():
                raise ProofError("preserved generated binding is not a regular file")
            path.chmod(0o600)
        for name in directories:
            path = Path(current) / name
            if path.is_symlink():
                raise ProofError("preserved generated binding contains symlink")
            path.chmod(0o700)
    if tree_sha(copied_generated) != generated_hash:
        raise ProofError("preserved generated bindings differ from build output")
    bindgen = target_dir / "debug/uniffi-bindgen"
    copied_bindgen = None
    if bindgen.is_file() and not bindgen.is_symlink():
        copied_bindgen_path = destination / "uniffi-bindgen"
        shutil.copyfile(bindgen, copied_bindgen_path)
        copied_bindgen_path.chmod(0o700)
        copied_bindgen = {
            "path": "artifacts/uniffi-bindgen",
            "sha256": sha256(copied_bindgen_path),
        }
    source_binding = {
        "sourceCommit": SOURCE_COMMIT,
        "sourceTreeSHA256": SOURCE_TREE,
        "sourceCargoLockSHA256": SOURCE_LOCK_SHA,
        "candidateCargoLockSHA256": CANDIDATE_LOCK_SHA,
        "patchSHA256": dict(PATCH_SHAS),
    }
    receipt["artifacts"] = {
        **(receipt.get("artifacts", {}) if isinstance(receipt.get("artifacts"), dict) else {}),
        "dylibPath": "artifacts/libbitwarden_uniffi.dylib",
        "dylibSHA256": sha256(copied_dylib),
        "dylibMinimumMacOS": "26.0",
        "generatedSwiftPath": "artifacts/GeneratedSwift",
        "generatedSwiftTreeSHA256": tree_sha(copied_generated),
        "sourcePatchBinding": source_binding,
        "uniffiBindgen": copied_bindgen,
    }


def owned_endpoint(value: str) -> bool:
    try:
        parsed = urlsplit(value)
        return (parsed.scheme == "http" and parsed.hostname == "127.0.0.1"
                and parsed.port is not None and parsed.username is None
                and parsed.password is None and not parsed.query and not parsed.fragment
                and parsed.path == "/")
    except ValueError:
        return False


class MockHandler(http.server.BaseHTTPRequestHandler):
    state: dict[str, object] = {}
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args: object) -> None:
        return

    def setup(self) -> None:
        super().setup()
        self.connection.settimeout(4)

    def reply(self, status: int, value: dict[str, object]) -> None:
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def reply_text(self, status: int, value: str) -> None:
        body = value.encode("ascii")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def unexpected(self, status: int = 404) -> None:
        self.state["unexpectedRequests"] = int(self.state.get("unexpectedRequests", 0)) + 1
        self.reply(status, {})

    def do_POST(self) -> None:
        try:
            if self.client_address[0] != "127.0.0.1" or self.headers.get("Transfer-Encoding"):
                self.reply(400, {})
                return
            if self.path == "/probe/release-late-login":
                if self.headers.get("Content-Length") not in (None, "0"):
                    self.reply(400, {})
                    return
                self.state["releaseLateLogin"].set()
                if not self.state["lateResponseFinished"].wait(5):
                    self.reply(503, {})
                    return
                self.state["lateResponseFinished"].clear()
                self.reply(200, {"released": True})
                return
            length_text = self.headers.get("Content-Length", "")
            if not re.fullmatch(r"[0-9]{1,6}", length_text):
                self.reply(400, {})
                return
            length = int(length_text)
            if length > 65536:
                self.reply(413, {})
                return
            raw = self.rfile.read(length)
            if len(raw) != length:
                self.reply(400, {})
                return
            if self.path == "/identity/accounts/prelogin/password":
                request = json.loads(raw)
                matched = isinstance(request, dict) and request.get("email") == self.state["email"]
                self.state["preloginRequests"] = int(self.state["preloginRequests"]) + 1
                if not matched:
                    self.reply(400, {})
                else:
                    self.reply(200, {"kdfSettings": {"kdfType": 0,
                                                       "iterations": self.state["iterations"]},
                                     "salt": self.state["email"]})
                return
            if self.path == "/identity/connect/token":
                fields = {key: values[0] for key, values in parse_qs(
                    raw.decode("ascii"), keep_blank_values=True, strict_parsing=True).items()}
                matched = (
                    self.headers.get("Content-Type", "").split(";")[0]
                    == "application/x-www-form-urlencoded"
                    and fields.get("client_id") == "arcusis-browser-synthetic-probe"
                    and fields.get("deviceIdentifier")
                    == "00000000-0000-4000-8000-000000000026"
                    and fields.get("deviceName") == "Synthetic Swift Probe"
                    and fields.get("deviceType") == "21"
                    and fields.get("username") == self.state["email"]
                    and fields.get("password") == self.state["passwordHash"]
                )
                self.state["validLoginRequests"] = int(self.state["validLoginRequests"]) + int(matched)
                self.state["rejectedLoginRequests"] = int(self.state["rejectedLoginRequests"]) + int(not matched)
                if matched:
                    if int(self.state["validLoginRequests"]) > 1:
                        self.state["lateLoginWaiting"].set()
                        self.state["lateResponsesHeld"] = int(self.state["lateResponsesHeld"]) + 1
                        if not self.state["releaseLateLogin"].wait(30):
                            self.reply(503, {})
                            return
                        self.state["releaseLateLogin"].clear()
                        self.state["lateLoginWaiting"].clear()
                        self.state["lateResponsesReleased"] = (
                            int(self.state["lateResponsesReleased"]) + 1)
                        self.state["lateResponseFinished"].set()
                    self.reply(200, self.state["loginResponse"])
                else:
                    self.reply(400, {"error": "invalid_grant"})
                return
            self.unexpected()
        except (OSError, ValueError, TypeError, UnicodeDecodeError):
            self.state["unexpectedRequests"] = int(self.state.get("unexpectedRequests", 0)) + 1
            try:
                self.reply(400, {})
            except OSError:
                pass

    def do_GET(self) -> None:
        try:
            if self.client_address[0] == "127.0.0.1" and self.path == "/probe/late-login-waiting":
                state = "waiting" if self.state["lateLoginWaiting"].is_set() else "not-ready"
                self.reply_text(200, state)
                return
            if self.client_address[0] != "127.0.0.1" or not self.path.startswith("/api/sync"):
                self.unexpected()
                return
            expected = f"Bearer {self.state['accessToken']}"
            matched = self.headers.get("Authorization") == expected
            self.state["syncRequests"] = int(self.state["syncRequests"]) + 1
            self.state["validSyncAuthorization"] = matched
            self.reply(200 if matched else 401, self.state["syncResponse"] if matched else {})
        except (OSError, ValueError, TypeError):
            self.state["unexpectedRequests"] = int(self.state.get("unexpectedRequests", 0)) + 1
            try:
                self.reply(400, {})
            except OSError:
                pass


class OwnedServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = False
    daemon_threads = True

    def handle_error(self, *_args: object) -> None:
        return


def listener_refused(address: tuple[str, int]) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.settimeout(0.5)
        return probe.connect_ex(address) != 0


def _unique_json_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON key")
        value[key] = item
    return value


def prepared_output(data: bytes) -> dict[str, str]:
    if len(data) > MAX_NATIVE_OUTPUT_BYTES:
        raise ProofError("SDK preparation output exceeds bound")
    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        raise ProofError("SDK preparation output has invalid encoding") from None
    marker = PREPARED_OUTPUT_MARKER.decode("ascii")
    records = [line[len(marker):] for line in text.splitlines()
               if line.startswith(marker)]
    if len(records) != 1 or not records[0]:
        raise ProofError("SDK preparation output marker missing or duplicated")
    try:
        value = json.loads(records[0], object_pairs_hook=_unique_json_object)
    except ValueError:
        raise ProofError("SDK preparation output has invalid shape") from None
    if (not isinstance(value, dict) or set(value) != {
            "passwordHash", "newKey", "encryptedCipherBase64"}
            or any(not isinstance(value[key], str) or not value[key] for key in value)):
        raise ProofError("SDK preparation output incomplete")
    return value


def build_success_response(vector: dict[str, object], prepared: dict[str, str]) -> dict[str, object]:
    return {
        "access_token": "synthetic-lifecycle-access-token",
        "expires_in": 3600,
        "token_type": "Bearer",
        "refresh_token": "synthetic-lifecycle-refresh-token",
        "scope": "api offline_access",
        "PrivateKey": vector["loginPrivateKey"],
        "AccountKeys": {"publicKeyEncryptionKeyPair": {
            "wrappedPrivateKey": vector["loginPrivateKey"],
            "publicKey": vector["loginPublicKey"],
            "Object": "publicKeyEncryptionKeyPair"}, "Object": "privateKeys"},
        "Key": prepared["newKey"], "Kdf": 0,
        "KdfIterations": vector["iterations"], "KdfMemory": None, "KdfParallelism": None,
        "MasterPasswordPolicy": {"Object": "masterPasswordPolicy"},
        "ForcePasswordReset": False,
        "UserDecryptionOptions": {"HasMasterPassword": True,
            "MasterPasswordUnlock": {"Kdf": {"KdfType": 0,
                "Iterations": vector["iterations"]},
                "MasterKeyEncryptedUserKey": prepared["newKey"],
                "Salt": vector["email"]}, "Object": "userDecryptionOptions"},
    }


def compile_probe(work: Path, checkout: Path, dylib: Path, generated: Path,
                  env: dict[str, str], receipt: dict[str, object]) -> Path:
    support = checkout / "crates/bitwarden-uniffi/swift/Sources/BitwardenSdkSupport/NaiveDateFormatter.swift"
    if support.is_symlink() or not support.is_file():
        raise ProofError("pinned Swift SDK support source unavailable")
    support_object = work / "BitwardenSdkSupport.o"
    support_module = work / "BitwardenSdkSupport.swiftmodule"
    run_command(["swiftc", "-parse-as-library", "-target", "arm64-apple-macosx26.0",
                 "-module-name", "BitwardenSdkSupport", "-emit-module", "-emit-module-path",
                 str(support_module), "-emit-object", "-o", str(support_object), str(support)],
                cwd=work, env=env, timeout=90, label="swift_sdk_support", receipt=receipt)
    sources = sorted(str(path) for path in generated.glob("*.swift"))
    module_maps = sorted(str(path) for path in generated.glob("*.modulemap"))
    if not sources or not module_maps or not (generated / "BitwardenFFI.modulemap").is_file():
        raise ProofError("matching generated Swift bindings incomplete")
    module_flags = [arg for path in module_maps for arg in ("-Xcc", f"-fmodule-map-file={path}")]
    executable = work / "native-vault-lifecycle"
    command = ["swiftc", "-parse-as-library", "-target", "arm64-apple-macosx26.0",
               "-I", str(work),
               "-I", str(generated), *module_flags, "-L", str(dylib.parent),
               "-lbitwarden_uniffi", "-Xlinker", "-rpath", "-Xlinker", str(dylib.parent),
               *sources, str(support_object),
               str(ROOT / "Sources/BrowserCore/PasswordAuthenticationGate.swift"),
               str(ROOT / "Sources/BrowserCore/PasswordCredentialStore.swift"),
               str(ROOT / "Tests/NativeBitwardenLifecycleProbe/Fixtures.swift"),
               str(ROOT / "Tests/NativeBitwardenLifecycleProbe/main.swift"),
               "-o", str(executable)]
    run_command(command, cwd=work, env=env, timeout=300,
                label="swift_native_probe_build", receipt=receipt)
    minos = run_command(["vtool", "-show-build", str(dylib)], cwd=work, env=env,
                        timeout=20, label="dylib_minimum_os", receipt=receipt)
    if not re.search(r"minos\s+26\.0(?:\s|$)", minos.stdout):
        raise ProofError("SDK dylib minimum macOS differs from pin")
    executable_minos = run_command(["vtool", "-show-build", str(executable)], cwd=work,
                                   env=env, timeout=20, label="executable_minimum_os",
                                   receipt=receipt)
    if not re.search(r"minos\s+26\.0(?:\s|$)", executable_minos.stdout):
        raise ProofError("Swift probe minimum macOS differs from pin")
    return executable


def preflight(args: argparse.Namespace) -> tuple[
    dict[str, object], dict[str, Path], Path, dict[str, object], Path,
    dict[str, str], dict[str, object]
]:
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ProofError("native lifecycle requires arm64 macOS")
    output = args.output.expanduser().absolute()
    source = args.source.expanduser().absolute()
    if output.exists() or output.is_symlink() or not output.parent.is_dir():
        raise ProofError("output must be fresh beneath existing parent")
    if source.is_symlink() or not source.is_dir():
        raise ProofError("pristine SDK source unavailable or symlinked")
    pin, patches = read_pin(args.candidate)
    receipt: dict[str, object] = {"commands": []}
    env = {key: os.environ[key] for key in (
        "PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "SDKROOT", "RUSTUP_HOME", "CARGO_HOME")
        if key in os.environ}
    env.update({
        "RUSTUP_TOOLCHAIN": TOOLCHAIN, "CARGO_BUILD_JOBS": "2",
        "CARGO_NET_OFFLINE": "true", "MACOSX_DEPLOYMENT_TARGET": "26.0",
        "CARGO_TERM_COLOR": "never", "SWIFT_DETERMINISTIC_HASHING": "1",
        "RUSTFLAGS": "-C link-arg=-Wl,-application_extension "
        "-C link-arg=-mmacosx-version-min=26.0 --cfg bitwarden_ensure_non_commercial",
    })
    # Cheap source, fixture, patch, toolchain, and output checks finish before Cargo tests/build.
    source, vector = verify_source(source, env, receipt)
    check_toolchain(env, receipt)
    source_digests()
    return pin, patches, source, vector, output, env, receipt


def run(args: argparse.Namespace) -> int:
    pin, patches, source, vector, output, env, receipt = preflight(args)
    create_private_root(output)
    work = Path(tempfile.mkdtemp(prefix="private-work-", dir=output))
    work.chmod(0o700)
    sdk = work / "sdk-internal"
    target_dir = work / "cargo-target"
    receipt.update({
        "schema": 1, "status": "running", "accepted": pin["accepted"],
        "integration_ready": False, "candidate": args.candidate,
        "source": {"repository": pin["repository"], "commit": SOURCE_COMMIT,
                   "treeSHA256": SOURCE_TREE, "cargoLockSHA256": SOURCE_LOCK_SHA},
        "patches": dict(PATCH_SHAS), "candidateCargoLockSHA256": CANDIDATE_LOCK_SHA,
        "changedFiles": 22, "runtimeHost": {"system": platform.system(),
            "version": platform.mac_ver()[0], "architecture": platform.machine()},
        "sdkDeploymentTarget": "26.0", "credentialAuthorityMode": "synthetic_https_identity",
        "tlsAuthorityBindingAccepted": False, "browserCoreSources": source_digests(),
        "rustRegression": {"passed": 0, "failed": 0, "suiteSummaries": 0,
                           "checks": []},
    })
    server: OwnedServer | None = None
    server_thread: threading.Thread | None = None
    try:
        clone = run_command(["git", "clone", "--local", "--no-hardlinks", "--no-checkout",
                             str(source), str(sdk)], cwd=ROOT, env=env, timeout=120,
                            label="fresh_private_sdk_clone", receipt=receipt)
        del clone
        run_command(["git", "-C", str(sdk), "checkout", "--detach", SOURCE_COMMIT],
                    cwd=ROOT, env=env, timeout=30, label="pinned_sdk_checkout", receipt=receipt)
        patch_counts = {"auth": 15, "clear": 2, "sync": 5}
        reported_paths: set[str] = set()
        for name in ("auth", "clear", "sync"):
            patch = patches[name]
            stats = run_command(["git", "-C", str(sdk), "apply", "--numstat", str(patch)],
                                cwd=ROOT, env=env, timeout=30,
                                label=f"{name}_patch_numstat", receipt=receipt)
            paths = {line.split("\t")[-1] for line in stats.stdout.splitlines() if line.strip()}
            if len(paths) != patch_counts[name] or paths != patch_paths(patch):
                raise ProofError(f"{name} patch numstat differs from pinned file set")
            if reported_paths & paths:
                raise ProofError("SDK patches overlap changed paths")
            reported_paths.update(paths)
            run_command(["git", "-C", str(sdk), "apply", "--check", "--whitespace=error", str(patch)],
                        cwd=ROOT, env=env, timeout=30, label=f"{name}_patch_check", receipt=receipt)
            run_command(["git", "-C", str(sdk), "apply", "--whitespace=error", str(patch)],
                        cwd=ROOT, env=env, timeout=60, label=f"{name}_patch_apply", receipt=receipt)
        if reported_paths != CHANGED_PATHS:
            raise ProofError("SDK patch numstat union differs from exact 22-path contract")
        run_command(["git", "-C", str(sdk), "diff", "--check"], cwd=ROOT, env=env,
                    timeout=30, label="candidate_diff_check", receipt=receipt)
        changed = run_command(["git", "-C", str(sdk), "status", "--porcelain=v1", "--untracked-files=all"],
                              cwd=ROOT, env=env, timeout=30, label="candidate_changed_paths", receipt=receipt)
        changed_paths = {line[3:] for line in changed.stdout.splitlines() if len(line) > 3}
        if changed_paths != CHANGED_PATHS:
            raise ProofError("fresh candidate does not contain exact 22 SDK paths")
        if sha256(sdk / "Cargo.lock") != CANDIDATE_LOCK_SHA:
            raise ProofError("candidate Cargo.lock differs from pinned patch composition")
        receipt["candidateSource"] = {"changedPaths": sorted(changed_paths),
                                      "treeFingerprintSHA256": worktree_sha(sdk)}
        build_env = dict(env, CARGO_TARGET_DIR=str(target_dir))
        common = ["--offline", "--locked", "--manifest-path", str(sdk / "Cargo.toml"),
                  "--target", TARGET]
        rust_results = []
        for label, command, package, features, test_filter in (
            ("key_clear_rust_regression", ["cargo", "test", *common, "--package", "bitwarden-core",
             "--features", "internal,test-fixtures", "test_clear_user_crypto_keys_rejects_key_reads"], None, None, None),
            ("sync_rust_regression", ["cargo", "test", *common, "--package", "bitwarden-sync"], None, None, None),
        ):
            del package, features, test_filter
            result = run_command(command, cwd=sdk, env=build_env, timeout=1800,
                                 label=label, receipt=receipt, check=False)
            passed, failed, suites = parse_test_count(result.stdout + "\n" + result.stderr)
            rust_results.append((passed, failed, suites))
            receipt["rustRegression"] = {
                "passed": sum(item[0] for item in rust_results),
                "failed": sum(item[1] for item in rust_results),
                "suiteSummaries": sum(item[2] for item in rust_results),
                "checks": [
                    {"name": name, "passed": counts[0], "failed": counts[1],
                     "suiteSummaries": counts[2]}
                    for name, counts in zip(
                        ("key_clear_rust_regression", "sync_rust_regression"), rust_results)
                ],
            }
            validate_rust_regression(result.returncode, (passed, failed, suites), label)
        build = run_command(["cargo", "build", *common, "--package", "bitwarden-uniffi"],
                            cwd=sdk, env=build_env, timeout=3600,
                            label="single_uniffi_build", receipt=receipt)
        del build
        dylib = target_dir / TARGET / "debug/libbitwarden_uniffi.dylib"
        if dylib.is_symlink() or not dylib.is_file():
            raise ProofError("fresh SDK dylib missing")
        generated = work / "GeneratedSwift"
        generated.mkdir(mode=0o700)
        run_command(["cargo", "run", *common, "--package", "uniffi-bindgen", "--",
                     "generate", str(dylib), "--language", "swift", "--no-format",
                     "--out-dir", str(generated)], cwd=sdk, env=build_env, timeout=900,
                    label="single_matching_swift_bindings", receipt=receipt)
        receipt["artifacts"] = {
            "dylibSHA256": sha256(dylib), "generatedSwiftTreeSHA256": tree_sha(generated),
            "dylibMinimumMacOS": "26.0",
            "probeMainSHA256": sha256(ROOT / "Tests/NativeBitwardenLifecycleProbe/main.swift"),
            "probeFixturesSHA256": sha256(ROOT / "Tests/NativeBitwardenLifecycleProbe/Fixtures.swift"),
        }
        executable = compile_probe(work, sdk, dylib, generated, env, receipt)
        fixture = dict(vector)
        fixture["newPassword"] = secrets.token_urlsafe(32)
        # Run probe fixture preparation once; run_native owns HTTP server and lifecycle run.
        preparation = subprocess.run(
            [str(executable), "prepare"], cwd=work, env=env,
            input=json.dumps(fixture, separators=(",", ":")).encode(),
            capture_output=True, timeout=180)
        receipt["nativeStages"] = {"preparationExitCode": preparation.returncode}
        if preparation.returncode:
            raise ProofError("SDK public fixture preparation failed")
        if len(preparation.stdout) + len(preparation.stderr) > MAX_NATIVE_OUTPUT_BYTES:
            raise ProofError("SDK preparation output exceeds bound")
        prepared = prepared_output(preparation.stdout)
        del preparation
        success = build_success_response(vector, prepared)
        cipher = json.loads(base64.b64decode(
            prepared["encryptedCipherBase64"], validate=True))
        MockHandler.state = {
            "email": vector["email"], "iterations": vector["iterations"],
            "passwordHash": prepared["passwordHash"],
            "accessToken": success["access_token"], "loginResponse": success,
            "syncResponse": {"profile": {"id": vector["userID"], "email": vector["email"],
                                             "emailVerified": True},
                             "folders": [], "ciphers": [cipher], "sends": [],
                             "policiesNew": [], "userDecryption": {}},
            "preloginRequests": 0, "validLoginRequests": 0, "rejectedLoginRequests": 0,
            "syncRequests": 0, "validSyncAuthorization": False,
            "lateLoginWaiting": threading.Event(), "releaseLateLogin": threading.Event(),
            "lateResponseFinished": threading.Event(),
            "lateResponsesHeld": 0, "lateResponsesReleased": 0,
            "unexpectedRequests": 0,
        }
        server = OwnedServer(("127.0.0.1", 0), MockHandler)
        server_thread = threading.Thread(target=server.serve_forever, daemon=True)
        server_thread.start()
        endpoint = f"http://127.0.0.1:{server.server_address[1]}/"
        if not owned_endpoint(endpoint):
            raise ProofError("runner-owned SDK HTTP origin failed loopback validation")
        final_fixture = dict(fixture)
        final_fixture.update(prepared)
        lifecycle = subprocess.run(
            [str(executable), endpoint, "lifecycle"], cwd=work, env=env,
            input=json.dumps(final_fixture, separators=(",", ":")).encode(),
            capture_output=True, timeout=420)
        receipt["nativeStages"] = {"lifecycleExitCode": lifecycle.returncode}
        server.shutdown()
        server.server_close()
        server_thread.join(timeout=5)
        cleanup = {
            "nativeProcessExited": lifecycle.returncode is not None,
            "mockThreadStopped": not server_thread.is_alive(),
            "mockListenerClosed": server.socket.fileno() == -1,
            "mockListenerRefusedReconnect": listener_refused(server.server_address),
        }
        receipt["mock"] = {
            "preloginRequestCount": MockHandler.state["preloginRequests"],
            "validLoginRequestCount": MockHandler.state["validLoginRequests"],
            "rejectedLoginRequestCount": MockHandler.state["rejectedLoginRequests"],
            "syncRequestCount": MockHandler.state["syncRequests"],
            "validSyncAuthorization": MockHandler.state["validSyncAuthorization"],
            "lateResponsesHeld": MockHandler.state["lateResponsesHeld"],
            "lateResponsesReleased": MockHandler.state["lateResponsesReleased"],
            "transport": "owned_loopback_http",
        }
        receipt["cleanup"] = cleanup
        if len(lifecycle.stdout) + len(lifecycle.stderr) > MAX_NATIVE_OUTPUT_BYTES:
            raise ProofError("native lifecycle output exceeds bound")
        try:
            lifecycle_output = lifecycle.stdout.decode("utf-8", errors="strict")
        except UnicodeDecodeError:
            raise ProofError("native lifecycle output has invalid encoding") from None
        stages = validate_stage_output(lifecycle_output, MockHandler.state)
        receipt["stages"] = stages
        receipt["nativeStageCount"] = sum(stages.values())
        mock_counts = observed_mock_counts(MockHandler.state)
        receipt["mockCounts"] = mock_counts
        error_match = re.search(r"^native_vault_error_type=([A-Za-z0-9_.]+)$",
                                lifecycle_output, re.M)
        if error_match:
            receipt["nativeFailureClass"] = error_match.group(1)
        stage_match = re.search(r"^native_vault_stage=([A-Za-z0-9_.]+)$",
                                lifecycle_output, re.M)
        if stage_match:
            receipt["nativeFailureStage"] = stage_match.group(1)
        if mock_counts != EXPECTED_MOCK_COUNTS:
            receipt["mockCountContractPassed"] = False
            raise ProofError("native lifecycle mock request counts differ from contract")
        receipt["mockCountContractPassed"] = True
        cleanup["syntheticCredentialRecordsRemoved"] = stages.get(
            "credential_records_removed") is True
        receipt["cleanup"] = cleanup
        if not all(cleanup.values()):
            raise ProofError("mock server cleanup observation failed")
        if lifecycle.returncode or not all(stages.values()):
            raise ProofError("actual SDK login/sync/lock lifecycle failed")
        receipt["tlsAuthorityBindingAccepted"] = False
        receipt["status"] = "candidate_succeeded" if args.candidate else "succeeded"
        preserve_build_artifacts(work, output, receipt)
        if not remove_private_work(work):
            raise ProofError("private work cleanup failed")
        receipt["privateWorkRemoved"] = True
        write_receipt(output, receipt)
        return 0
    except (ProofError, OSError, ValueError, TypeError, KeyError,
            subprocess.TimeoutExpired) as error:
        receipt["status"] = "candidate_failed" if args.candidate else "failed"
        receipt["failure"] = str(error) if isinstance(error, ProofError) else "private_probe_error"
        if server is not None:
            try:
                if "releaseLateLogin" in MockHandler.state:
                    MockHandler.state["releaseLateLogin"].set()
                server.shutdown()
                server.server_close()
            except OSError:
                pass
        if server_thread is not None:
            server_thread.join(timeout=5)
        if work.exists():
            try:
                preserve_build_artifacts(work, output, receipt)
            except (OSError, ProofError):
                receipt["artifactPreservationFailed"] = True
            try:
                shutil.rmtree(work, ignore_errors=True)
            except OSError:
                pass
        receipt["privateWorkRemoved"] = not work.exists()
        try:
            write_receipt(output, receipt)
        except (OSError, ProofError):
            pass
        print(str(error) if isinstance(error, ProofError) else "native lifecycle failed", file=sys.stderr)
        return 1
    finally:
        if server is not None and server.socket.fileno() != -1:
            try:
                if "releaseLateLogin" in MockHandler.state:
                    MockHandler.state["releaseLateLogin"].set()
                server.shutdown()
                server.server_close()
            except OSError:
                pass
        if server_thread is not None:
            server_thread.join(timeout=5)
        if work.exists():
            try:
                shutil.rmtree(work, ignore_errors=True)
            except OSError:
                pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", action="store_true",
                        help="run explicitly unaccepted candidate pin")
    parser.add_argument("--source", required=True, type=Path,
                        help="pristine pinned SDK source checkout")
    parser.add_argument("--output", required=True, type=Path,
                        help="fresh private proof directory")
    args = parser.parse_args()
    try:
        return run(args)
    except (ProofError, OSError, ValueError, TypeError) as error:
        print(str(error) if isinstance(error, ProofError) else "preflight failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
