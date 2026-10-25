#!/usr/bin/env python3
"""Build and run isolated pinned SDK key-clear proof offline on arm64 macOS."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE_COMMIT = "5cf919837e83b71c2508bf99344ea57cf5f84e88"
SOURCE_TREE = "9af9432aefeed6796e40e5019ffdc8600f3381e9"
CARGO_LOCK_SHA = "0496b9d35a9c6fd84f79bcc46aa774aa8a86f09eb8c64ba568bc18f4abd0c46a"
AUTH_PATCH_SHA = "850c53c73c710772b338bc88760543f66562119984e25bcf0337bfa986842a91"
TARGET = "aarch64-apple-darwin"
TOOLCHAIN = "1.90-aarch64-apple-darwin"


class ProofError(Exception):
    def __init__(self, code: str):
        self.code = code


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tree_sha(root: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ProofError("generated_tree_symlink")
        if path.is_file():
            digest.update(path.relative_to(root).as_posix().encode() + b"\0")
            digest.update(bytes.fromhex(sha256(path)) + b"\n")
    return digest.hexdigest()


def run(command: list[str], *, cwd: Path, env: dict[str, str], timeout: int,
        label: str, results: list[dict[str, object]], check: bool = True
        ) -> subprocess.CompletedProcess[str]:
    recorded_env = {key: env[key] for key in (
        "RUSTUP_TOOLCHAIN", "CARGO_TARGET_DIR", "CARGO_BUILD_JOBS", "MACOSX_DEPLOYMENT_TARGET",
        "RUSTFLAGS", "CARGO_NET_OFFLINE", "CARGO_TERM_COLOR") if key in env}
    try:
        result = subprocess.run(command, cwd=cwd, env=env, capture_output=True,
                                text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        results.append({"name": label, "argv": command, "cwd": str(cwd),
                        "environment": recorded_env, "exitCode": None, "result": "timeout"})
        raise ProofError(label + "_timeout") from None
    results.append({"name": label, "argv": command, "cwd": str(cwd),
                    "environment": recorded_env, "exitCode": result.returncode,
                    "result": "passed" if result.returncode == 0 else "failed"})
    if label == "swift_probe_build" and result.returncode:
        diagnostics = []
        for line in (result.stdout + "\n" + result.stderr).splitlines():
            match = re.search(r"([^/\\]+\.swift):(\d+):(\d+): (error|warning):", line)
            if match:
                diagnostics.append({"file": match.group(1), "line": int(match.group(2)),
                                    "column": int(match.group(3)), "severity": match.group(4)})
        results[-1]["diagnostics"] = diagnostics[:30]
    if result.returncode and check:
        raise ProofError(label + "_failed")
    return result


def read_pin(candidate: bool) -> tuple[dict[str, object], Path, Path]:
    spike = ROOT / "ThirdParty/BitwardenKeyClearSpike"
    pin_path = spike / "pin.json"
    try:
        if pin_path.is_symlink():
            raise ProofError("pin_symlink")
        pin = json.loads(pin_path.read_text(encoding="utf-8"))
        if not isinstance(pin, dict):
            raise ProofError("pin_shape_invalid")
        if pin.get("patchFile") != "clear-crypto-keys.patch":
            raise ProofError("clear_patch_path_mismatch")
        if pin.get("authPatch") != "../BitwardenAuthSpike/identity-mfa.patch":
            raise ProofError("auth_patch_path_mismatch")
        clear_patch = spike / "clear-crypto-keys.patch"
        auth_patch = ROOT / "ThirdParty/BitwardenAuthSpike/identity-mfa.patch"
        if clear_patch.is_symlink() or auth_patch.is_symlink():
            raise ProofError("patch_symlink")
        auth_pin_path = ROOT / "ThirdParty/BitwardenAuthSpike/pin.json"
        if auth_pin_path.is_symlink():
            raise ProofError("auth_pin_symlink")
        auth_pin = json.loads(auth_pin_path.read_text(encoding="utf-8"))
    except (OSError, ValueError, KeyError, TypeError):
        raise ProofError("pin_or_patch_unavailable") from None
    if (not isinstance(pin, dict) or type(pin.get("schema")) is not int or pin.get("schema") != 1
            or type(pin.get("accepted")) is not bool
            or pin.get("repository") != "https://github.com/bitwarden/sdk-internal"
            or pin.get("sourceCommit") != SOURCE_COMMIT or pin.get("rustToolchain") != TOOLCHAIN
            or pin.get("target") != TARGET or pin.get("minMacOS") != "26.0"
            or pin.get("authPatchSHA256") != AUTH_PATCH_SHA
            or not isinstance(auth_pin, dict) or type(auth_pin.get("schema")) is not int
            or auth_pin.get("schema") != 1 or type(auth_pin.get("accepted")) is not bool
            or auth_pin.get("accepted") is not True
            or auth_pin.get("repository") != "https://github.com/bitwarden/sdk-internal"
            or auth_pin.get("sourceCommit") != SOURCE_COMMIT
            or auth_pin.get("patchFile") != "identity-mfa.patch"
            or auth_pin.get("patchSHA256") != AUTH_PATCH_SHA
            or auth_pin.get("patchBytes") != auth_patch.stat().st_size
            or auth_pin.get("changedFiles") != 15
            or auth_pin.get("rustToolchain") != TOOLCHAIN
            or auth_pin.get("target") != TARGET
            or auth_pin.get("minMacOS") != "26.0"
            or sha256(auth_patch) != AUTH_PATCH_SHA):
        raise ProofError("pin_mismatch")
    if pin["accepted"] is False and not candidate:
        raise ProofError("candidate_requires_explicit_flag")
    if pin["accepted"] is True and candidate:
        raise ProofError("candidate_flag_requires_unaccepted_pin")
    if not clear_patch.is_file() or sha256(clear_patch) != pin.get("patchSHA256"):
        raise ProofError("clear_patch_missing_or_mismatched")
    if pin.get("patchBytes") != clear_patch.stat().st_size or pin.get("changedFiles") != 2:
        raise ProofError("clear_patch_metadata_mismatch")
    return pin, auth_patch, clear_patch


def validate_source(source: Path, results: list[dict[str, object]], env: dict[str, str]) -> Path:
    if source.is_symlink() or not source.is_dir():
        raise ProofError("source_unavailable")
    head = run(["git", "rev-parse", "HEAD"], cwd=source, env=env, timeout=10,
               label="source_head", results=results)
    status = run(["git", "status", "--porcelain=v1", "--untracked-files=no"], cwd=source,
                 env=env, timeout=10, label="source_status", results=results)
    if head.stdout.strip() != SOURCE_COMMIT or status.stdout.strip():
        raise ProofError("source_not_pristine_pin")
    lock = source / "Cargo.lock"
    if lock.is_symlink() or not lock.is_file():
        raise ProofError("cargo_lock_missing")
    return source.resolve(strict=True)


def fixture_values(source: Path) -> dict[str, object]:
    """Extract coherent synthetic unlock inputs from the pinned SDK test vector."""
    path = source / "crates/bitwarden-core/src/client/test_accounts.rs"
    if path.is_symlink() or not path.is_file():
        raise ProofError("pinned_fixture_missing")
    text = path.read_text(encoding="utf-8")
    start = text.find("pub fn test_bitwarden_com_account()")
    end = text.find("pub fn test_bitwarden_com_account_v2()", start)
    if start < 0 or end <= start:
        raise ProofError("pinned_fixture_shape_invalid")
    function = text[start:end]

    def extract(pattern: str) -> str:
        match = re.search(pattern, function, re.S)
        if not match:
            raise ProofError("pinned_fixture_incomplete")
        return match.group(1)

    try:
        user_id = extract(r"user_id: Some\(UserId::new\(uuid::uuid!\(\"([^\"]+)\"\)\)\)")
        private_key = extract(r'account_cryptographic_state: WrappedAccountCryptographicState::V1 \{\s*private_key: "([^"\\]+)"\.parse::<EncString>')
        wrapped_key = extract(r'master_key_wrapped_user_key: "([^"\\]+)"\.parse\(\)')
        password = extract(r'method: InitUserCryptoMethod::MasterPasswordUnlock \{\s*password: "([^"\\]+)"')
    except ProofError:
        raise
    return {"userId": user_id, "email": "test@bitwarden.com", "password": password,
            "privateKey": private_key,
            "masterKeyWrappedUserKey": wrapped_key, "iterations": 600000}


def write_private_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, separators=(",", ":")) + "\n", encoding="utf-8")
    path.chmod(0o600)


def verify_candidate_diff(sdk: Path, auth_patch: Path, clear_patch: Path,
                          env: dict[str, str], results: list[dict[str, object]]) -> str:
    expected = {"crates/bitwarden-core/src/key_management/crypto_client.rs",
                "crates/bitwarden-uniffi/src/crypto.rs"}
    auth_expected = set(re.findall(r"^diff --git a/(.*?) b/", auth_patch.read_text(encoding="utf-8"), re.M))
    full_expected = expected | auth_expected
    if len(auth_expected) != 15:
        raise ProofError("auth_patch_scope_mismatch")
    paths = run(["git", "status", "--porcelain=v1", "--untracked-files=all"], cwd=sdk, env=env,
                timeout=10, label="candidate_diff_paths", results=results)
    names = {line[3:] for line in paths.stdout.splitlines() if len(line) > 3}
    if names != full_expected:
        raise ProofError("candidate_diff_paths_mismatch")
    patch_names = set(re.findall(r"^diff --git a/(.*?) b/", clear_patch.read_text(encoding="utf-8"), re.M))
    if patch_names != expected:
        raise ProofError("candidate_patch_scope_mismatch")
    for path in sorted(full_expected):
        file_path = sdk / path
        if file_path.is_symlink() or not file_path.is_file() or not file_path.resolve().is_relative_to(sdk):
            raise ProofError("candidate_changed_path_invalid")

    def changed_content_digest() -> str:
        digest = hashlib.sha256()
        for path in sorted(full_expected):
            digest.update(path.encode() + b"\0")
            digest.update(bytes.fromhex(sha256(sdk / path)) + b"\n")
        return digest.hexdigest()

    applied_digest = changed_content_digest()
    run(["git", "apply", "--reverse", "--check", str(clear_patch)], cwd=sdk,
        env=env, timeout=10, label="clear_patch_reverse_check", results=results)
    run(["git", "apply", "--reverse", "--check", str(auth_patch)], cwd=sdk,
        env=env, timeout=10, label="auth_patch_reverse_check", results=results)
    run(["git", "apply", "--reverse", str(clear_patch)], cwd=sdk,
        env=env, timeout=20, label="clear_patch_reverse", results=results)
    run(["git", "apply", "--reverse", str(auth_patch)], cwd=sdk,
        env=env, timeout=20, label="auth_patch_reverse", results=results)
    pristine = run(["git", "status", "--porcelain=v1", "--untracked-files=all"], cwd=sdk,
                   env=env, timeout=10, label="candidate_reversed_status", results=results)
    tree = run(["git", "rev-parse", "HEAD^{tree}"], cwd=sdk, env=env,
               timeout=10, label="candidate_reversed_tree", results=results)
    if pristine.stdout.strip() or tree.stdout.strip() != SOURCE_TREE:
        raise ProofError("candidate_reverse_not_pristine")
    for patch, label in ((auth_patch, "auth_patch_reapply"), (clear_patch, "clear_patch_reapply")):
        run(["git", "apply", "--check", str(patch)], cwd=sdk, env=env,
            timeout=10, label=label + "_check", results=results)
        run(["git", "apply", str(patch)], cwd=sdk, env=env,
            timeout=20, label=label, results=results)
    final_status = run(["git", "status", "--porcelain=v1", "--untracked-files=all"], cwd=sdk,
                       env=env, timeout=10, label="candidate_final_status", results=results)
    final_names = {line[3:] for line in final_status.stdout.splitlines() if len(line) > 3}
    if final_names != full_expected or changed_content_digest() != applied_digest:
        raise ProofError("candidate_reapply_not_identical")
    return applied_digest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path, help="pristine pinned local SDK checkout")
    parser.add_argument("--output", required=True, type=Path, help="fresh private proof directory")
    parser.add_argument("--candidate", action="store_true",
                        help="run unaccepted candidate patch in isolated proof mode")
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ProofError("requires_arm64_macos")

    pin, auth_patch, clear_patch = read_pin(candidate=args.candidate)
    output_arg = args.output.expanduser()
    if not output_arg.is_absolute():
        output_arg = Path.cwd() / output_arg
    if output_arg.name in ("", ".", ".."):
        raise ProofError("output_path_invalid")
    try:
        output = output_arg.parent.resolve(strict=True) / output_arg.name
    except OSError:
        raise ProofError("output_parent_unavailable") from None
    source_arg = args.source.expanduser()
    if source_arg.is_symlink() or not source_arg.exists():
        raise ProofError("source_unavailable_or_symlinked")
    try:
        source = source_arg.resolve(strict=True)
    except OSError:
        raise ProofError("source_unavailable") from None
    if source.is_relative_to(output) or output.is_relative_to(source):
        raise ProofError("source_and_output_must_be_separate")
    if output.exists() or output.is_symlink() or not output.parent.is_dir():
        raise ProofError("output_must_be_fresh")

    results: list[dict[str, object]] = []
    env = {key: os.environ[key] for key in (
        "PATH", "HOME", "TMPDIR", "DEVELOPER_DIR", "SDKROOT", "RUSTUP_HOME", "CARGO_HOME")
        if key in os.environ}
    env.update({"RUSTUP_TOOLCHAIN": TOOLCHAIN, "CARGO_BUILD_JOBS": "2",
                "CARGO_NET_OFFLINE": "true", "MACOSX_DEPLOYMENT_TARGET": "26.0",
                "CARGO_TERM_COLOR": "never", "SWIFT_DETERMINISTIC_HASHING": "1",
                "RUSTFLAGS": "-C link-arg=-Wl,-application_extension -C link-arg=-mmacosx-version-min=26.0 --cfg bitwarden_ensure_non_commercial"})
    rustc_version = run(["rustc", "--version"], cwd=ROOT, env=env, timeout=10,
                        label="rustc_version", results=results)
    cargo_version = run(["cargo", "--version"], cwd=ROOT, env=env, timeout=10,
                        label="cargo_version", results=results)
    if not rustc_version.stdout.startswith("rustc 1.90.") or not cargo_version.stdout.startswith("cargo 1.90."):
        raise ProofError("rust_toolchain_version_mismatch")
    targets = run(["rustup", "target", "list", "--installed"], cwd=ROOT, env=env, timeout=20,
                  label="installed_targets", results=results)
    if TARGET not in targets.stdout.splitlines():
        raise ProofError("required_rust_target_missing")
    source = validate_source(source, results, env)
    source_tree = run(["git", "rev-parse", "HEAD^{tree}"], cwd=source, env=env,
                      timeout=10, label="source_tree", results=results).stdout.strip()
    cargo_lock_sha = sha256(source / "Cargo.lock")
    if source_tree != SOURCE_TREE or cargo_lock_sha != CARGO_LOCK_SHA:
        raise ProofError("pinned_source_tree_or_lock_mismatch")

    output.mkdir(mode=0o700)
    output.chmod(0o700)
    work = output / "private-work"
    work.mkdir(mode=0o700)
    receipt: dict[str, object] = {
        "schema": 1,
        "scope": "native_swift_shared_key_store_clear",
        "candidate": args.candidate,
        "accepted": pin["accepted"],
        "integration_ready": False,
        "status": "running",
        "sourceCommit": SOURCE_COMMIT,
        "sourceTree": source_tree,
        "cargoLockSHA256": cargo_lock_sha,
        "authPatchSHA256": AUTH_PATCH_SHA,
        "clearPatchSHA256": sha256(clear_patch),
        "rustToolchain": TOOLCHAIN,
        "target": TARGET,
        "minMacOS": "26.0",
        "commands": results,
    }
    try:
        sdk = output / "sdk-internal"
        run(["git", "clone", "--local", "--no-hardlinks", "--no-checkout", str(source), str(sdk)],
            cwd=output, env=env, timeout=120, label="offline_local_clone", results=results)
        run(["git", "-C", str(sdk), "checkout", "--detach", SOURCE_COMMIT], cwd=output,
            env=env, timeout=60, label="pinned_source_checkout", results=results)
        for patch, label in ((auth_patch, "accepted_auth_patch"), (clear_patch, "candidate_clear_patch")):
            run(["git", "apply", "--check", str(patch)], cwd=sdk, env=env,
                timeout=20, label=label + "_check", results=results)
            run(["git", "apply", str(patch)], cwd=sdk, env=env,
                timeout=20, label=label + "_apply", results=results)
        run(["git", "diff", "--check"], cwd=sdk, env=env, timeout=20,
            label="candidate_diff_check", results=results)
        candidate_tree_fingerprint = verify_candidate_diff(sdk, auth_patch, clear_patch, env, results)

        build_env = dict(env)
        build_env["CARGO_TARGET_DIR"] = str(output / "cargo-target")
        common = ["--offline", "--locked", "--manifest-path", str(sdk / "Cargo.toml"), "--target", TARGET]
        test = run(["cargo", "test", *common, "--package", "bitwarden-core",
                    "--features", "internal,test-fixtures",
                    "test_clear_user_crypto_keys_rejects_key_reads"],
                   cwd=sdk, env=build_env, timeout=1200, label="focused_rust_regression",
                   results=results, check=False)
        test_matches = re.findall(r"test result: (ok|FAILED)\. (\d+) passed; (\d+) failed;",
                                  test.stdout + "\n" + test.stderr)
        passed = sum(int(item[1]) for item in test_matches if item[0] == "ok")
        failed = sum(int(item[2]) + (int(item[1]) if item[0] == "FAILED" else 0)
                     for item in test_matches)
        receipt["rustRegression"] = {"passed": passed, "failed": failed,
                                      "suiteSummaries": len(test_matches)}
        if results and results[-1].get("name") == "focused_rust_regression":
            results[-1]["result"] = "passed" if test.returncode == 0 and passed > 0 and failed == 0 else "failed"
        if test.returncode or passed < 1 or failed != 0 or not test_matches:
            raise ProofError("focused_rust_regression_missing_or_failed")
        del test

        run(["cargo", "build", *common, "--package", "bitwarden-uniffi"],
            cwd=sdk, env=build_env, timeout=1800, label="uniffi_build", results=results)
        dylib = Path(build_env["CARGO_TARGET_DIR"]) / TARGET / "debug" / "libbitwarden_uniffi.dylib"
        if dylib.is_symlink() or not dylib.is_file():
            raise ProofError("uniffi_dylib_missing")
        generated = output / "GeneratedSwift"
        generated.mkdir(mode=0o700)
        run(["cargo", "run", *common, "--package", "uniffi-bindgen", "--",
             "generate", str(dylib), "--language", "swift", "--no-format", "--out-dir", str(generated)],
            cwd=sdk, env=build_env, timeout=600, label="uniffi_swift_bindings", results=results)
        if not any(generated.glob("*.swift")) or not any(generated.glob("*.modulemap")):
            raise ProofError("generated_swift_missing")

        support = sdk / "crates/bitwarden-uniffi/swift/Sources/BitwardenSdkSupport/NaiveDateFormatter.swift"
        if support.is_symlink() or not support.is_file():
            raise ProofError("pinned_support_source_missing")
        shutil.copy2(support, work / "NaiveDateFormatter.swift")
        swift_root = ROOT / "Tests/NativeBitwardenKeyClearProbe"
        shutil.copy2(swift_root / "main.swift", work / "main.swift")
        shutil.copy2(swift_root / "Fixtures.swift", work / "Fixtures.swift")
        fixture_path = work / "synthetic-fixture.json"
        write_private_json(fixture_path, fixture_values(source))
        sources = sorted(str(path) for path in generated.glob("*.swift"))
        modules = sorted(str(path) for path in generated.glob("*.modulemap"))
        module_flags = [item for path in modules for item in ("-Xcc", f"-fmodule-map-file={path}")]
        support_obj = work / "BitwardenSdkSupport.o"
        support_module = work / "BitwardenSdkSupport.swiftmodule"
        run(["swiftc", "-parse-as-library", "-target", "arm64-apple-macosx26.0",
             "-module-name", "BitwardenSdkSupport", "-emit-module", "-emit-module-path",
             str(support_module), "-emit-object", "-o", str(support_obj), str(support)],
            cwd=work, env=env, timeout=120, label="swift_support_build", results=results)
        executable = work / "key-clear-probe"
        run(["swiftc", "-parse-as-library", "-target", "arm64-apple-macosx26.0",
             "-I", str(generated), "-I", str(work), *module_flags,
             "-L", str(dylib.parent), "-lbitwarden_uniffi", "-Xlinker", "-rpath",
             "-Xlinker", str(dylib.parent), *sources, str(support_obj),
             str(work / "Fixtures.swift"), str(work / "main.swift"), "-o", str(executable)],
            cwd=work, env=env, timeout=300, label="swift_probe_build", results=results)
        dylib_minos = run(["vtool", "-show-build", str(dylib)], cwd=work, env=env,
                          timeout=20, label="dylib_minos_check", results=results)
        executable_minos = run(["vtool", "-show-build", str(executable)], cwd=work, env=env,
                               timeout=20, label="executable_minos_check", results=results)
        if "minos 26.0" not in dylib_minos.stdout or "minos 26.0" not in executable_minos.stdout:
            raise ProofError("macos_minimum_mismatch")
        probe_env = dict(env)
        probe_env["BITWARDEN_FIXTURE_PATH"] = str(fixture_path)
        probe = run([str(executable)], cwd=work, env=probe_env, timeout=180,
                    label="native_swift_probe", results=results)
        required = {"cipher_round_trip=passed", "retained_key_read=rejected",
                    "retained_cipher_decrypt=rejected", "independent_client=preserved",
                    "explicit_reinitialization=passed", "key_clear_proof=passed"}
        if not required.issubset(set(probe.stdout.splitlines())):
            raise ProofError("native_swift_stage_missing")
        shutil.copy2(dylib, output / "libbitwarden_uniffi.dylib")
        status = run(["git", "status", "--porcelain=v1", "--untracked-files=all"], cwd=sdk,
                     env=env, timeout=30, label="candidate_source_paths", results=results)
        changed_paths = sorted(line[3:] for line in status.stdout.splitlines() if len(line) > 3)
        receipt.update({
            "candidateSource": {"patchSHA256": sha256(clear_patch),
                                "treeFingerprintSHA256": candidate_tree_fingerprint,
                                "changedPaths": changed_paths},
            "buildGuard": {"rustflags": env["RUSTFLAGS"], "cargoJobs": 2,
                           "offline": True, "deploymentTarget": "26.0"},
            "stages": {"cipherRoundTrip": True, "retainedKeyReadRejected": True,
                       "retainedCipherDecryptRejected": True, "independentClientPreserved": True,
                       "explicitReinitialization": True},
            "artifacts": {"dylibSHA256": sha256(dylib),
                          "generatedSwiftTreeSHA256": tree_sha(generated),
                          "dylibMinimumMacOS": "26.0",
                          "swiftProbeSourceSHA256": sha256(swift_root / "main.swift"),
                          "swiftFixtureSourceSHA256": sha256(swift_root / "Fixtures.swift"),
                          "fixtureSource": "pinned_sdk_test_account"},
            "scopeNotes": ["shared in-memory SDK keys only", "host bridge lifecycle remains separate",
                           "tokens and persisted state untouched", "no caller plaintext erasure claim",
                           "no memory zeroization claim"],
            "host": {"system": "Darwin", "architecture": "arm64", "macOS": platform.mac_ver()[0]},
            "status": "candidate_succeeded" if args.candidate else "succeeded"})
        shutil.rmtree(work)
        write_private_json(output / "receipt.json", receipt)
        print("key_clear_proof=passed")
        print("scope=native_swift_shared_key_store_clear")
        print("macos_minimum=26.0")
        return 0
    except ProofError as exc:
        receipt["status"] = "failed"
        receipt["error"] = exc.code
        try:
            write_private_json(output / "receipt.json", receipt)
        except OSError:
            pass
        print(f"key_clear_proof=failed reason={exc.code}", file=sys.stderr)
        return 2
    except (OSError, ValueError, TypeError, KeyError):
        receipt["status"] = "failed"
        receipt["error"] = "runner_internal_error"
        try:
            write_private_json(output / "receipt.json", receipt)
        except OSError:
            pass
        print("key_clear_proof=failed reason=runner_internal_error", file=sys.stderr)
        return 2
    finally:
        if work.exists():
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
