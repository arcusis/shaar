#!/usr/bin/env python3
"""Run a pinned, isolated Foundation-only strict backend fixture."""
from __future__ import annotations

import argparse
import base64
import hashlib
import importlib.util
import json
import os
import re
import shutil
import signal
import socket
import stat
import subprocess
import threading
import time
from pathlib import Path, PurePosixPath
from urllib.parse import parse_qs

RECEIPT_SHA256 = "d5cadc8fcd0e231b9578aff1613a75cfb95aa486beeb12f84439ac70167a3c70"
ROOT_HEAD = "62a01b48505d2b1cb119c3f35937ae8bfae59f27"
HELPER_SHA256 = "cfb4653252fe700e34c8d8ae735e989657b8d355cb36c63588b81e3b2cf2c680"
EXTRACTOR_SHA256 = "ed4436414633d5d89be69d7ef89f241e775f13b5a5b9c6ad167884ea05d807bb"
VECTOR_SHA256 = "2347b7c7b3856b4672c38354fcaa00b0a2bb8afdbf842145230328bb6b9fb2c7"
CIPHER_ID = "11111111-1111-4111-8111-111111111111"
XCTEST = "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest"
PACKAGE = '''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "ArcusisBrowser", platforms: [.macOS("26.0")],
  dependencies: [.package(name: "SDKPackage", path: "../SDKPackage")], targets: [
    .target(name: "BrowserCore", resources: [.process("Resources/public_suffix_list.dat")]),
    .target(name: "ArcusisBrowser", dependencies: ["BrowserCore", .product(name: "ArcusisBitwardenSDK", package: "SDKPackage")], swiftSettings: [.define("ARCUSIS_NATIVE_BITWARDEN_ORGANIZATION_CANDIDATE"), .define("ARCUSIS_NATIVE_BITWARDEN_REFRESH_CANDIDATE"), .define("ARCUSIS_NATIVE_BITWARDEN_REFRESH_FIXTURE"), .define("ARCUSIS_NATIVE_BITWARDEN_STRICT_SDK")]),
    .testTarget(name: "BrowserAppTests", dependencies: ["ArcusisBrowser", "BrowserCore", .product(name: "ArcusisBitwardenSDK", package: "SDKPackage")], swiftSettings: [.define("ARCUSIS_NATIVE_BITWARDEN_REFRESH_FIXTURE"), .define("ARCUSIS_NATIVE_BITWARDEN_STRICT_SDK")]),
  ])
'''
INPUTS = frozenset({
    "Package.swift",
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
    "Tests/BrowserAppTests/NativeBitwardenStrictBackendTests.swift",
    "scripts/test-native-bitwarden-strict-backend.py",
    "Tests/NativeBitwardenStrictBackendRunnerTests/test_strict_backend_runner.py",
})


class GuardError(ValueError):
    pass


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise GuardError("duplicate JSON key")
        result[key] = value
    return result


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def hex_hash(value) -> bool:
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def safe_path(root: Path, name: str) -> Path:
    if not root.is_absolute() or not isinstance(name, str) or "\\" in name:
        raise GuardError("invalid path")
    parts = name.split("/")
    if any(part in ("", ".", "..") for part in parts) or PurePosixPath(name).is_absolute():
        raise GuardError("invalid relative path")
    for parent in (root, *root.parents):
        if parent.is_symlink():
            raise GuardError("symlink root")
    path = root
    for part in parts:
        path = path / part
        if path.is_symlink():
            raise GuardError("symlink input")
    return path


def read_regular(path: Path) -> bytes:
    try:
        if not stat.S_ISREG(path.lstat().st_mode):
            raise GuardError("non-regular input")
        return path.read_bytes()
    except OSError as error:
        raise GuardError("input unavailable") from error


def parse_json(data: bytes):
    try:
        return json.loads(data, object_pairs_hook=unique)
    except (ValueError, UnicodeError) as error:
        raise GuardError("invalid JSON") from error


def verify_checkpoint(root: Path, manifest: Path, expected_sha: str) -> dict[str, str]:
    if not hex_hash(expected_sha) or not manifest.is_absolute():
        raise GuardError("invalid checkpoint pin")
    for component in (manifest, *manifest.parents):
        if component.is_symlink():
            raise GuardError("symlink checkpoint")
    data = read_regular(manifest)
    if sha(data) != expected_sha:
        raise GuardError("checkpoint digest mismatch")
    value = parse_json(data)
    if not isinstance(value, dict) or set(value) != {"schema", "baseCommit", "files"}:
        raise GuardError("checkpoint schema")
    if type(value["schema"]) is not int or value["schema"] != 1 or value["baseCommit"] != ROOT_HEAD:
        raise GuardError("checkpoint provenance")
    files = value["files"]
    if not isinstance(files, dict) or set(files) != INPUTS:
        raise GuardError("checkpoint inventory")
    for name, expected in files.items():
        if not hex_hash(expected) or sha(read_regular(safe_path(root, name))) != expected:
            raise GuardError("input digest mismatch")
    return files


def inventory(root: Path) -> dict[str, str]:
    if not root.is_absolute() or any(p.is_symlink() for p in (root, *root.parents)):
        raise GuardError("invalid package root")
    if not root.is_dir():
        raise GuardError("package unavailable")
    result = {}
    for current, dirs, files in os.walk(root, followlinks=False):
        for name in dirs:
            path = Path(current) / name
            if not stat.S_ISDIR(path.lstat().st_mode):
                raise GuardError("non-directory package entry")
        for name in files:
            path = Path(current) / name
            result[path.relative_to(root).as_posix()] = sha(read_regular(path))
    return result


def verify_package(receipt_path: Path, package: Path, mode: str) -> None:
    if mode not in ("debug", "release") or any(p.is_symlink() for p in (receipt_path, *receipt_path.parents)):
        raise GuardError("invalid package selection")
    data = read_regular(receipt_path)
    if sha(data) != RECEIPT_SHA256:
        raise GuardError("receipt digest mismatch")
    receipt = parse_json(data)
    if (not isinstance(receipt, dict) or receipt.get("accepted") is not False
            or receipt.get("integrationReady") is not False):
        raise GuardError("receipt status")
    entries = receipt.get("packages", {}).get(mode, {})
    expected = entries.get("files")
    if (entries.get("testOnly") is not (mode == "debug") or not isinstance(expected, dict)
            or len(expected) != 84 or inventory(package) != expected):
        raise GuardError("package inventory mismatch")


def load_pinned(path: Path, expected: str, module_name: str):
    if any(p.is_symlink() for p in (path, *path.parents)) or sha(read_regular(path)) != expected:
        raise GuardError("helper digest mismatch")
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise GuardError("helper import unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if sha(read_regular(path)) != expected:
        raise GuardError("helper changed while importing")
    return module


def public_fixture(source: Path, extractor: Path):
    vector_path = safe_path(source, "crates/bitwarden-core/src/client/test_accounts.rs")
    data = read_regular(vector_path)
    if sha(data) != VECTOR_SHA256:
        raise GuardError("public vector digest mismatch")
    module = load_pinned(extractor, EXTRACTOR_SHA256, "strict_vector_extractor")
    vector = module.sdk_vector(source)
    text = data.decode("utf-8")
    section = text.split("INSERT INTO vault_dev.dbo.[User]", 1)[1].split(
        "INSERT INTO vault_dev.dbo.Organization", 1)[0]
    match = re.search(r"N\s*'(MIIBIjAN[^']+)'", section)
    if not match:
        raise GuardError("public vector missing key")
    claims = json.dumps({"sub": vector["userID"], "client_id": "desktop",
                         "exp": int(time.time()) + 3600, "scope": ["api"]}).encode()
    token = "e30." + base64.urlsafe_b64encode(claims).decode().rstrip("=") + ".c2ln"
    response = {
        "access_token": token, "expires_in": 3600, "token_type": "Bearer",
        "refresh_token": "synthetic-initial", "scope": "api offline_access",
        "PrivateKey": vector["privateKey"],
        "AccountKeys": {"publicKeyEncryptionKeyPair": {"wrappedPrivateKey": vector["privateKey"],
            "publicKey": match.group(1), "Object": "publicKeyEncryptionKeyPair"}, "Object": "privateKeys"},
        "Key": vector["wrappedUserKey"], "MasterPasswordPolicy": {"Object": "masterPasswordPolicy"},
        "ForcePasswordReset": False, "Kdf": 0, "KdfIterations": vector["iterations"],
        "KdfMemory": None, "KdfParallelism": None,
        "UserDecryptionOptions": {"HasMasterPassword": True,
            "MasterPasswordUnlock": {"Kdf": {"KdfType": 0, "Iterations": vector["iterations"]},
                "MasterKeyEncryptedUserKey": vector["wrappedUserKey"], "Salt": vector["email"]},
            "Object": "userDecryptionOptions"},
    }
    return vector, token, response


def host_handler(helper, vector, token, response):
    class Handler(helper.Handler):
        def do_POST(self):
            if self.path not in ("/identity/accounts/prelogin/password", "/identity/connect/token"):
                return super().do_POST()
            try:
                self.count_request()
                if self.client_address[0] != "127.0.0.1" or self.headers.get("Transfer-Encoding"):
                    raise GuardError("auth boundary")
                length = int(self.headers.get("Content-Length", "-1"))
                if not 0 <= length <= 65536:
                    raise GuardError("auth length")
                raw = self.rfile.read(length)
                if len(raw) != length:
                    raise GuardError("auth truncation")
                if self.path.endswith("/password"):
                    if parse_json(raw).get("email") != vector["email"]:
                        raise GuardError("prelogin input")
                    self.server.prelogins += 1
                    self.send_json(200, {"kdfSettings": {"kdfType": 0,
                        "iterations": vector["iterations"]}, "salt": vector["email"]})
                else:
                    form = parse_qs(raw.decode(), keep_blank_values=True)
                    if form.get("grant_type") != ["password"] or form.get("client_id") != ["desktop"]:
                        raise GuardError("login input")
                    self.server.logins += 1
                    self.send_json(200, response)
            except (ValueError, OSError, KeyError):
                self.note_error("auth rejected")
                self.send_json(400, {})

        def authorize(self):
            if self.headers.get("Authorization") != "Bearer " + token:
                raise GuardError("token mismatch")
            self.headers.replace_header("Authorization", "Bearer synthetic-owned-token")

        def do_GET(self):
            if self.path.startswith("/api/sync"):
                try:
                    self.authorize()
                except GuardError:
                    self.note_error("sync token rejected")
                    return self.send_json(400, {})
            return super().do_GET()

        def do_PUT(self):
            try:
                self.authorize()
                self.server.pending.set()
                if not self.server.release.wait(5):
                    raise GuardError("write release timeout")
                return super().do_PUT()
            except GuardError:
                self.note_error("write rejected")
                return self.send_json(400, {})
    return Handler


def run_build(command: list[str], cwd: Path, log: Path, timeout: int) -> bytes:
    environment = {key: os.environ[key] for key in ("PATH", "HOME", "TMPDIR") if key in os.environ}
    try:
        with log.open("xb") as output:
            os.chmod(log, 0o600)
            process = subprocess.Popen(command, cwd=cwd, env=environment, stdin=subprocess.DEVNULL,
                                       stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                code = process.wait(timeout=timeout)
            finally:
                if process.poll() is None:
                    if os.getpgid(process.pid) != process.pid:
                        raise GuardError("compiler process identity changed")
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
                try:
                    os.killpg(process.pid, 0)
                except ProcessLookupError:
                    pass
                else:
                    raise GuardError("compiler process group survived")
    finally:
        if log.exists() and log.stat().st_size > 262144:
            with log.open("rb") as source:
                source.seek(-262144, os.SEEK_END)
                tail = source.read()
            log.write_bytes(tail)
            os.chmod(log, 0o600)
    data = read_regular(log)
    if code != 0:
        raise GuardError("compiler failed")
    return data


def run_test(command: list[str], cwd: Path, extra: dict[str, str], result: dict, timeout: int) -> None:
    environment = {key: os.environ[key] for key in ("PATH", "HOME", "TMPDIR") if key in os.environ}
    environment.update(extra)
    process = subprocess.Popen(command, cwd=cwd, env=environment, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        output, _ = process.communicate(timeout=timeout)
        # Retain line numbers only. XCTest output can contain credential values.
        result["failureLines"] = sorted({int(match.group(1)) for match in re.finditer(
            rb"NativeBitwardenStrictBackendTests\.swift:(\d+):\s*error:", output)})
        stages = ("first-sync", "preflight", "replacement-sync", "unconfirmed",
                  "reconciliation-sync", "credential", "complete")
        result["stages"] = [stage for stage in stages if ("strict-stage: " + stage).encode() in output]
        error_cases = ("staleAccess", "operationInProgress", "ineligibleCipher", "noMatchingURI",
                       "unsupportedMatch", "cipherUnavailable", "invalidSnapshot", "syncFailed")
        result["knownErrorCases"] = [case for case in error_cases if case.encode() in output]
        result["xctestExitCode"] = process.returncode
        if process.returncode != 0 or b"Executed 1 test, with 0 failures" not in output:
            raise GuardError("named XCTest failed")
    finally:
        if process.poll() is None:
            try:
                if os.getpgid(process.pid) != process.pid:
                    raise GuardError("test process identity changed")
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        process.wait(timeout=5)
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise GuardError("test process group survived")
        if process.stdout is not None:
            process.stdout.close()


def run_backend(args, result: dict) -> None:
    before = verify_checkpoint(args.source_root, args.source_manifest, args.source_manifest_sha256)
    verify_package(args.receipt, args.debug_package, "debug")
    helper = load_pinned(args.transport_helper, HELPER_SHA256, "strict_transport_helper")
    vector, token, response = public_fixture(args.sdk_source, args.extractor)
    base = safe_path(Path(__file__).resolve().parents[1], "build/NativeBitwardenStrictBackend")
    if args.output.parent != base or not args.output.is_absolute() or args.output.exists() or args.output.is_symlink():
        raise GuardError("fresh owned output required")
    base.mkdir(parents=True, exist_ok=True)
    safe_path(Path(__file__).resolve().parents[1], "build/NativeBitwardenStrictBackend")
    if sha(read_regular(Path(__file__).resolve())) != before["scripts/test-native-bitwarden-strict-backend.py"]:
        raise GuardError("running runner differs from checkpoint")
    args.output.mkdir(mode=0o700)
    result["outputCreated"] = True
    package = args.output / "SDKPackage"
    shutil.copytree(args.debug_package, package)
    verify_package(args.receipt, package, "debug")
    harness = args.output / "harness"
    harness.mkdir()
    for name in sorted(INPUTS):
        if not (name.startswith("Sources/") or name == "Tests/BrowserAppTests/NativeBitwardenStrictBackendTests.swift"):
            continue
        destination = harness / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(safe_path(args.source_root, name), destination)
        if sha(read_regular(destination)) != before[name]:
            raise GuardError("staged input mismatch")
    (harness / "Package.swift").write_text(PACKAGE)
    def check_staged():
        for name in INPUTS:
            if name.startswith("Sources/") or name == "Tests/BrowserAppTests/NativeBitwardenStrictBackendTests.swift":
                if sha(read_regular(safe_path(harness, name))) != before[name]:
                    raise GuardError("staged source changed")
        if read_regular(harness / "Package.swift") != PACKAGE.encode():
            raise GuardError("harness package changed")
        if (sha(read_regular(args.transport_helper)) != HELPER_SHA256
                or sha(read_regular(args.extractor)) != EXTRACTOR_SHA256
                or sha(read_regular(safe_path(args.sdk_source, "crates/bitwarden-core/src/client/test_accounts.rs"))) != VECTOR_SHA256):
            raise GuardError("fixture source changed")
        verify_checkpoint(args.source_root, args.source_manifest, args.source_manifest_sha256)
        verify_package(args.receipt, args.debug_package, "debug")
        verify_package(args.receipt, package, "debug")
    check_staged()
    scratch = args.output / "swift-build"
    cache = args.output / "swift-cache"
    cache.mkdir(mode=0o700)
    runtime_lib = package / "Frameworks/BitwardenSDK.xcframework/macos-arm64"
    build = ["/usr/bin/sandbox-exec", "-p", helper.BUILD_SANDBOX, "swift", "build",
             "--package-path", str(harness), "--scratch-path", str(scratch), "--cache-path", str(cache),
             "--build-tests", "--jobs", "2", "--disable-keychain", "--disable-netrc",
             "--disable-dependency-cache", "--disable-prefetching", "--manifest-cache", "none",
             "--disable-sandbox", "-Xlinker", "-rpath", "-Xlinker", str(runtime_lib)]
    result["phase"] = "build"
    run_build(build, args.output, args.output / "build.log", 300)
    lines = run_build(build + ["--show-bin-path"], args.output, args.output / "bin-path.log", 60).decode().splitlines()
    if len(lines) != 1:
        raise GuardError("ambiguous binary directory")
    bin_dir = Path(lines[0])
    if (not bin_dir.is_absolute() or ".." in bin_dir.parts or not bin_dir.is_dir()
            or any(part.is_symlink() for part in (bin_dir, *bin_dir.parents))
            or bin_dir.resolve(strict=True) != bin_dir or not bin_dir.is_relative_to(scratch)):
        raise GuardError("unsafe binary directory")
    check_staged()
    bundle = bin_dir / "BrowserAppTests.xctest"
    def check_resources():
        for root in (bin_dir, bundle / "Contents/Resources"):
            resource = root / "ArcusisBrowser_BrowserCore.bundle/Contents/Resources/public_suffix_list.dat"
            if sha(read_regular(helper.regular(resource))) != before["Sources/BrowserCore/Resources/public_suffix_list.dat"]:
                raise GuardError("resource bundle mismatch")
    check_resources()
    binary = bundle / "Contents/MacOS/BrowserAppTests"
    binary_hash = sha(read_regular(helper.regular(binary)))
    result["testBinarySHA256Before"] = binary_hash
    server = helper.Server()
    server.RequestHandlerClass = host_handler(helper, vector, token, response)
    server.prelogins = 0
    server.logins = 0
    address = server.server_address
    server.timeout = 0.1
    stop = threading.Event()
    def serve():
        while not stop.is_set():
            server.handle_request()
    worker = threading.Thread(target=serve, daemon=False)
    try:
        worker.start()
        result["phase"] = "xctest"
        fixture = {"endpoint": f"http://127.0.0.1:{address[1]}", "email": vector["email"],
                   "currentPassword": vector["currentPassword"], "cipherID": CIPHER_ID}
        extra = {"ARCUSIS_STRICT_BACKEND_FIXTURE": base64.b64encode(json.dumps(fixture).encode()).decode()}
        command = ["/usr/bin/sandbox-exec", "-p", helper.runtime_sandbox(address[1]), XCTEST,
                   "-XCTest", "BrowserAppTests.NativeBitwardenStrictBackendTests/testStrictPreparationLifecycle", str(bundle)]
        run_test(command, args.output, extra, result, 90)
    finally:
        server.release.set()
        stop.set()
        if worker.ident is not None:
            worker.join(timeout=6)
        with server.lock:
            active, threads = list(server.active), list(server.threads)
        for peer in active:
            try:
                peer.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            peer.close()
        server.server_close()
        for thread in threads:
            thread.join(timeout=6)
        result["threadsStopped"] = not worker.is_alive() and not any(thread.is_alive() for thread in threads)
        result["counts"] = {"prelogin": server.prelogins, "login": server.logins, "sync": server.syncs,
                            "put": server.puts, "requests": server.total, "errors": len(server.errors)}
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
            probe.settimeout(0.5)
            result["listenerClosed"] = probe.connect_ex(address) != 0
        result["testBinarySHA256After"] = sha(read_regular(helper.regular(binary)))
        check_staged()
        check_resources()
        if not result["threadsStopped"]:
            raise GuardError("fixture threads survived")
        if not result["listenerClosed"]:
            raise GuardError("listener survived")
    if server.errors or server.prelogins != 1 or server.logins != 1 or server.syncs != 3 or server.puts != 1:
        raise GuardError("fixture count mismatch")
    if result["testBinarySHA256After"] != binary_hash:
        raise GuardError("test binary changed")
    check_staged()
    result["status"] = "passed"
    result["phase"] = "complete"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--source-manifest", required=True, type=Path)
    parser.add_argument("--source-manifest-sha256", required=True)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--debug-package", required=True, type=Path)
    parser.add_argument("--run-fixture", action="store_true")
    parser.add_argument("--transport-helper", type=Path)
    parser.add_argument("--sdk-source", type=Path)
    parser.add_argument("--extractor", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.run_fixture:
        if any(value is None for value in (args.transport_helper, args.sdk_source, args.extractor, args.output)):
            parser.error("fixture requires transport helper, SDK source, extractor and fresh output")
        result = {"status": "incomplete", "phase": "validation", "outputCreated": False,
                  "sourceManifestSHA256": args.source_manifest_sha256, "productAcceptance": False}
        try:
            run_backend(args, result)
        except BaseException as error:
            result["errorType"] = type(error).__name__
            raise
        finally:
            if result["outputCreated"]:
                try:
                    verify_checkpoint(args.source_root, args.source_manifest, args.source_manifest_sha256)
                    verify_package(args.receipt, args.debug_package, "debug")
                    result["sourceAndPackageAfter"] = "matched"
                except Exception as error:
                    result["sourceAndPackageAfter"] = "mismatch"
                    result["integrityErrorType"] = type(error).__name__
                    result["status"] = "incomplete"
                receipt = args.output / "receipt.json"
                receipt.write_text(json.dumps(result, sort_keys=True, indent=2) + "\n")
                os.chmod(receipt, 0o600)
        if result["status"] != "passed":
            raise GuardError("final integrity failed")
        print("strict backend fixture passed; synthetic component proof only")
        return
    verify_checkpoint(args.source_root, args.source_manifest, args.source_manifest_sha256)
    verify_package(args.receipt, args.debug_package, "debug")
    print("input checkpoint verified; no fixture was run")


if __name__ == "__main__":
    main()
