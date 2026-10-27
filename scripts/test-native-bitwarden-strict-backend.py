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
from urllib.parse import parse_qs, urlsplit

RECEIPT_SHA256 = "d5cadc8fcd0e231b9578aff1613a75cfb95aa486beeb12f84439ac70167a3c70"
SDK9_RECEIPT_SHA256 = "9d6dd982c467bce5036f13a6c84bbcb38e223560114231816ddd89ea447f30e3"
SDK9_MANIFESTS = {"debug": "65583856b2d973ae175c3a8184f87e3cb127edf54f5242a21f58083296cb844c",
                  "release": "fd4b5d40bf571f5bc5f64e78741c8663925c8bea6b0ccb9891b2d28f1392326d"}
SERVICE_CANDIDATE_SHA256 = "9a202a82c43c72c116f2748683adb6c197be7c441ca41d83a5f31c906f20c50d"
SERVICE_PATCH_SHA256 = "8917fd3a357dd3a075391ba9d9aeefbf5343f8a665aebf58c4bdb457ca80d76c"
SERVICE_PRIMARY = {
    "BitwardenApiStartup.cs": "f6f8d5edbab88298bdd69bf7a4617b4a7e7b3e53b36266a5220d1fefc673aa20",
    "CipherResponseModel.cs": "5d03b29732a34d3bb2952b7d291d7ea77a3830c7b526ae80a13a47358bdc48d3",
    "CipherData.cs": "c70d82936c5d5d2dfab1cb66a4d30c8047ec5710902420b361536e0c9fdb59b9",
    "CipherFieldData.cs": "1d57095e665a3fee3666437c3ee7198acb101674e74957b193580bf0131e2191",
    "CipherFieldModel.cs": "be47b0c6ae1ee68d1bfdd757cab8819d6c0ce7cb201350d7dc7c185b0ccd6ea7",
    "CipherLoginData.cs": "ff274558fad5e275213e383e53bebb5433f9cd2cb8622a801ccf73c0ec26ab07",
    "CipherLoginModel.cs": "13fa0586973cc60b0824071341fa6e2824e8230a4fcae97dbd57ddb27e2a5f22",
    "CipherPasswordHistoryData.cs": "15245b3b4dd8bb16556f55f4de83813129f8447e2e25a954213e31282f06f888",
    "CipherPasswordHistoryModel.cs": "f079129837f77e276fb3354779546f9fb2d1b5352cf421d3da2def9e6b99cfbb",
    "CipherPermissionsResponseModel.cs": "e8830a03a3fc3db99684c0a77a56140f7fad203bf99f6fa588788825f6e00897",
    "CipherRequestModel.cs": "2bf00f62aab1332a77c7483d00eecdbb75ef9591a501fa2e647bc6c24a74e317",
    "CipherService.cs": "8afa818552819964d28bb40395b31b9684974a47686853021855c457c6ddf875",
    "NormalCipherPermissions.cs": "f7a1bd4ca3288d09a97610d63ada97b600bbda337a85e1d38bfd9d4ac0790834",
    "vaultwarden-cipher-model.rs": "c3ae6804d8dc2a6a914a9e9e95a97a98037d7f3cbde9421fc50ece10872c1c3a",
    "vaultwarden-ciphers.rs": "18c4cb7fb77b548b90716634a9b8041ca33a7f68df3e76a7aeeaded229924553",
}
ROOT_HEAD = "3f1d88b89257ce9680f57d2d353d2f09f1ed9a67"
HELPER_SHA256 = "cfb4653252fe700e34c8d8ae735e989657b8d355cb36c63588b81e3b2cf2c680"
EXTRACTOR_SHA256 = "ed4436414633d5d89be69d7ef89f241e775f13b5a5b9c6ad167884ea05d807bb"
VECTOR_SHA256 = "2347b7c7b3856b4672c38354fcaa00b0a2bb8afdbf842145230328bb6b9fb2c7"
ADMISSION_SHA256 = "bfd67db0eb69ca7ddb4e43125862b3f0408f8938fedcc286d1d90596fc7ea1c6"
ADMISSION_BEGIN = b"// BEGIN WRITE ADMISSION DECLARATION\n"
ADMISSION_END = b"// END WRITE ADMISSION DECLARATION\n"
ADMISSION_PROBE = b'''final class NativeBitwardenWriteAuthority: Sendable {
  struct Lease: Sendable {}
}
func attempt(_ authority: NativeBitwardenWriteAuthority, _ lease: NativeBitwardenWriteAuthority.Lease) {
  _ = NativeBitwardenWriteAdmission(authority: authority, lease: lease)
}
'''
LEGACY_MANIFESTS = {
    "sdk3": "8b19e0aad144a523135f56eab2e0ebd4b3a9612f5111969099411fc95c71c9b0",
    "sdk7": "dd2e42bb29bf52f94d9f6ee64fcb6a7f5ab6f09b18dda75b7b01432afe299d15",
}
CIPHER_ID = "11111111-1111-4111-8111-111111111111"
CREATED_ID = "22222222-2222-4222-8222-222222222222"
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
    "Sources/ArcusisBrowser/NativeBitwardenController.swift",
    "Sources/ArcusisBrowser/NativeBitwardenWriteAuthority.swift",
    "Sources/ArcusisBrowser/NativeBitwardenWrites.swift",
    "Sources/ArcusisBrowser/NativeBitwardenCipherRepository.swift",
    "Sources/ArcusisBrowser/NativeBitwardenFillCredential.swift",
    "Sources/ArcusisBrowser/NativeBitwardenVaultSnapshot.swift",
    "Sources/ArcusisBrowser/NativeBitwardenLogging.swift",
    "Sources/ArcusisBrowser/NativeBitwardenRefreshCoordinator.swift",
    "Tests/BrowserAppTests/NativeBitwardenStrictBackendTests.swift",
    "Tests/BrowserAppTests/NativeBitwardenWriteAuthorityTests.swift",
    "scripts/test-native-bitwarden-strict-backend.py",
    "Tests/NativeBitwardenStrictBackendRunnerTests/test_strict_backend_runner.py",
})


class GuardError(ValueError):
    pass


def compiled_input(name: str) -> bool:
    return ((name.startswith("Sources/") and name != "Sources/ArcusisBrowser/NativeBitwardenController.swift")
            or name in {"Tests/BrowserAppTests/NativeBitwardenStrictBackendTests.swift",
                        "Tests/BrowserAppTests/NativeBitwardenWriteAuthorityTests.swift"})


def admission_declaration(controller: bytes) -> bytes:
    if controller.count(ADMISSION_BEGIN) != 1 or controller.count(ADMISSION_END) != 1:
        raise GuardError("admission marker count")
    start = controller.index(ADMISSION_BEGIN)
    end = controller.index(ADMISSION_END) + len(ADMISSION_END)
    if start >= end:
        raise GuardError("admission marker order")
    block = controller[start:end]
    if sha(block) != ADMISSION_SHA256 or re.search(
            rb"(?m)^[ \t]*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^\r\n)]*\))?[ \t]+)*import\b", block):
        raise GuardError("admission declaration mismatch")
    return block


def is_expected_admission_denial(output: bytes, exit_code: int) -> bool:
    lines = [line for line in output.splitlines() if b"error:" in line and not line.lstrip().startswith(b"|")]
    if len(lines) != 1:
        return False
    header = re.fullmatch(rb"(?:.*/)?AdmissionAccessProbe\.swift:[0-9]+:[0-9]+: error: ([^\r\n]+)", lines[0])
    expected = b"'NativeBitwardenWriteAdmission' initializer is inaccessible due to 'fileprivate' protection level"
    return exit_code != 0 and header is not None and header.group(1) == expected


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


def verify_package(receipt_path: Path, package: Path, mode: str, profile: str = "sdk8") -> None:
    if profile not in ("sdk8", "sdk9"):
        raise GuardError("invalid SDK profile")
    if mode not in ("debug", "release") or any(p.is_symlink() for p in (receipt_path, *receipt_path.parents)):
        raise GuardError("invalid package selection")
    data = read_regular(receipt_path)
    if sha(data) != (SDK9_RECEIPT_SHA256 if profile == "sdk9" else RECEIPT_SHA256):
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
    if profile == "sdk9" and entries.get("manifestSHA256") != SDK9_MANIFESTS[mode]:
        raise GuardError("SDK9 manifest mismatch")


def verify_service_sources(primary: Path, candidate: Path, patch: Path) -> None:
    for path, digest in ((candidate, SERVICE_CANDIDATE_SHA256), (patch, SERVICE_PATCH_SHA256)):
        if not path.is_absolute() or any(part.is_symlink() for part in (path, *path.parents)):
            raise GuardError("unsafe service source")
        if sha(read_regular(path)) != digest:
            raise GuardError("service source mismatch")
    for name, digest in SERVICE_PRIMARY.items():
        if sha(read_regular(safe_path(primary, name))) != digest:
            raise GuardError("primary service source mismatch")
    value = parse_json(read_regular(candidate))
    if (not isinstance(value, dict) or value.get("primarySha256") != SERVICE_PRIMARY
            or value.get("patchSha256") != SERVICE_PATCH_SHA256
            or value.get("sourceCommit") != "5cf919837e83b71c2508bf99344ea57cf5f84e88"):
        raise GuardError("service candidate provenance mismatch")


def verify_legacy_package(package: Path, mode: str) -> None:
    if mode not in LEGACY_MANIFESTS:
        raise GuardError("legacy package mode")
    manifest_path = safe_path(package, "build-manifest.json")
    data = read_regular(manifest_path)
    if sha(data) != LEGACY_MANIFESTS[mode]:
        raise GuardError("legacy manifest mismatch")
    manifest = parse_json(data)
    if (not isinstance(manifest, dict) or type(manifest.get("schema")) is not int
            or manifest.get("schema") != 1 or manifest.get("integration_ready") is not False
            or manifest.get("sourceCommit") != "5cf919837e83b71c2508bf99344ea57cf5f84e88"
            or manifest.get("architecture") != "arm64" or manifest.get("minMacOS") != "26.0"
            or manifest.get("accepted") is not (mode == "sdk3")):
        raise GuardError("legacy package provenance")
    actual = inventory(package)
    actual.pop("build-manifest.json", None)
    if not isinstance(manifest.get("fileSHA256"), dict) or actual != manifest["fileSHA256"]:
        raise GuardError("legacy package inventory mismatch")


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


def service_record(original: dict, shape: str, fault: str | None = None) -> dict:
    if shape not in ("bitwarden", "vaultwarden") or fault not in (None, "data", "partial"):
        raise GuardError("unsupported synthetic service shape")
    record = json.loads(json.dumps(original))
    record.pop("partialData", None)
    record["permissions"] = {"delete": True, "restore": True}
    login = record["login"]
    uris = login.get("uris")
    login["uri"] = uris[0].get("uri") if uris else None
    if shape == "bitwarden" or fault == "data":
        data = {"Name": record.get("name"), "Notes": record.get("notes"),
                "Fields": None if record.get("fields") is None else [
                    {"Type": x.get("type"), "Name": x.get("name"), "Value": x.get("value"), "LinkedId": x.get("linkedId")}
                    for x in record["fields"]],
                "PasswordHistory": None if record.get("passwordHistory") is None else [
                    {"Password": x.get("password"), "LastUsedDate": x.get("lastUsedDate")}
                    for x in record["passwordHistory"]],
                "Uris": None if uris is None else [
                    {"Uri": x.get("uri"), "UriChecksum": x.get("uriChecksum"), "Match": x.get("match")}
                    for x in uris],
                "Username": login.get("username"), "Password": login.get("password"),
                "PasswordRevisionDate": login.get("passwordRevisionDate"), "Totp": login.get("totp"),
                "AutofillOnPageLoad": login.get("autofillOnPageLoad"), "Fido2Credentials": login.get("fido2Credentials")}
        def omit_null(value):
            if isinstance(value, dict):
                return {key: omit_null(item) for key, item in value.items() if item is not None}
            if isinstance(value, list):
                return [omit_null(item) for item in value]
            return value
        data = omit_null(data)
        if fault == "data":
            data["Name"] = "synthetic-contradiction"
        record["data"] = json.dumps(data, separators=(",", ":"))
    else:
        record.pop("data", None)
        record["organizationUseTotp"] = True
    if fault == "partial":
        record["partialData"] = "synthetic-partial"
    return record


def host_handler(helper, vector, token, response, shape=None):
    class Handler(helper.Handler):
        def do_POST(self):
            if self.path == "/api/ciphers":
                try:
                    self.count_request()
                    if (self.client_address[0] != "127.0.0.1" or self.headers.get("Transfer-Encoding")
                            or self.headers.get("Authorization") != "Bearer " + token):
                        raise GuardError("create boundary")
                    length = int(self.headers.get("Content-Length", "-1"))
                    if not 0 <= length <= 65536:
                        raise GuardError("create length")
                    raw = self.rfile.read(length)
                    if len(raw) != length or b"synthetic-create" in raw:
                        raise GuardError("create body")
                    obj = parse_json(raw)
                    login = obj.get("login")
                    if (not isinstance(login, dict) or not isinstance(obj.get("name"), str)
                            or not obj["name"].startswith("2.")
                            or any(not isinstance(login.get(key), str) or not login[key].startswith("2.")
                                   for key in ("username", "password"))):
                        raise GuardError("create encryption")
                    with self.server.lock:
                        self.server.creates += 1
                        if self.server.creates != 1:
                            raise GuardError("duplicate create")
                    self.server.create_pending.set()
                    if not self.server.create_release.wait(5):
                        raise GuardError("create release timeout")
                    record = json.loads(json.dumps(self.server.seed))
                    record.update({"id": CREATED_ID, "name": obj["name"], "notes": obj.get("notes"),
                        "key": obj.get("key"), "favorite": obj.get("favorite", False),
                        "attachments": None, "fields": None, "passwordHistory": None,
                        "revisionDate": "2025-01-01T00:00:00.123456791Z"})
                    record["login"] = {key: login.get(key) for key in ("uri", "uris", "username", "password",
                        "passwordRevisionDate", "totp", "autofillOnPageLoad", "fido2Credentials")}
                    if record["login"]["uris"] is not None:
                        record["login"]["uris"] = [{key: uri.get(key) for key in ("uri", "uriChecksum", "match")}
                                                  for uri in record["login"]["uris"]]
                    self.server.created = record
                    self.send_json(200, record)
                except (ValueError, OSError, KeyError, TypeError):
                    self.note_error("create rejected")
                    self.send_json(400, {})
                return
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
            if shape is not None and self.path in ("/fixture/shape-data", "/fixture/shape-partial", "/fixture/shape-valid"):
                try:
                    self.count_request()
                    if self.client_address[0] != "127.0.0.1":
                        raise GuardError("control boundary")
                    with self.server.lock:
                        self.server.controls += 1
                        if self.server.controls > 80:
                            raise GuardError("control count")
                        self.server.shape_fault = {"/fixture/shape-data": "data", "/fixture/shape-partial": "partial",
                                                   "/fixture/shape-valid": None}[self.path]
                    self.send_json(200, {})
                except (ValueError, OSError):
                    self.note_error("shape control rejected")
                return
            if shape is not None and self.path.startswith("/api/sync"):
                try:
                    self.count_request()
                    parts = urlsplit(self.path)
                    if (self.client_address[0] != "127.0.0.1" or parts.path != "/api/sync"
                            or parts.query not in ("", "excludeDomains=true", "excludeDomains=false")
                            or self.headers.get("Authorization") != "Bearer " + token or self.server.seed is None):
                        raise GuardError("sync boundary")
                    with self.server.lock:
                        self.server.syncs += 1
                        if self.server.syncs > 10:
                            raise GuardError("sync count")
                        originals = [self.server.seed] + ([self.server.created] if self.server.created else [])
                        records = [service_record(item, shape, self.server.shape_fault) for item in originals]
                    self.send_json(200, {"profile": {"organizations": []}, "folders": [], "sends": [],
                                         "policiesNew": [], "ciphers": records})
                except (ValueError, OSError, KeyError, TypeError):
                    self.note_error("service sync rejected")
                    self.send_json(400, {})
                return
            if self.path == "/fixture/count":
                try:
                    self.count_request()
                    if self.client_address[0] != "127.0.0.1":
                        raise GuardError("control boundary")
                    with self.server.lock:
                        self.server.controls += 1
                        if self.server.controls > 80:
                            raise GuardError("control count")
                        counts = {"put": self.server.puts, "create": self.server.creates}
                    self.send_json(200, counts)
                except (ValueError, OSError):
                    self.note_error("count control rejected")
                return
            if self.path in ("/fixture/create-status", "/fixture/create-release"):
                try:
                    self.count_request()
                    if self.client_address[0] != "127.0.0.1":
                        raise GuardError("control boundary")
                    with self.server.lock:
                        self.server.controls += 1
                        if self.server.controls > 80:
                            raise GuardError("control count")
                    if self.path.endswith("release"):
                        self.server.create_release.set()
                        return self.send_json(200, {})
                    data = b"ready" if self.server.create_pending.is_set() else b"waiting"
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                except (ValueError, OSError):
                    self.note_error("create control rejected")
                return
            if self.path.startswith("/api/sync") and self.server.created is not None:
                try:
                    self.count_request()
                    parts = urlsplit(self.path)
                    if (self.client_address[0] != "127.0.0.1" or parts.path != "/api/sync"
                            or parts.query not in ("", "excludeDomains=true", "excludeDomains=false")
                            or self.headers.get("Authorization") != "Bearer " + token):
                        raise GuardError("sync boundary")
                    with self.server.lock:
                        self.server.syncs += 1
                        if self.server.syncs > 10:
                            raise GuardError("sync count")
                        ciphers = json.loads(json.dumps([self.server.seed, self.server.created]))
                    self.send_json(200, {"profile": {"organizations": []}, "folders": [], "sends": [],
                                         "policiesNew": [], "ciphers": ciphers})
                except (ValueError, OSError, TypeError):
                    self.note_error("post-create sync rejected")
                    self.send_json(400, {})
                return
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


def run_admission_negative(helper, output_dir: Path, declaration_path: Path) -> None:
    probe = output_dir / "AdmissionAccessProbe.swift"
    probe.write_bytes(ADMISSION_PROBE)
    os.chmod(probe, 0o600)
    cache = output_dir / "admission-module-cache"
    cache.mkdir(mode=0o700)
    command = ["/usr/bin/sandbox-exec", "-p", helper.BUILD_SANDBOX, "swiftc", "-typecheck",
               "-parse-as-library", "-target", "arm64-apple-macosx26.0", "-module-cache-path", str(cache),
               str(declaration_path), str(probe)]
    environment = {key: os.environ[key] for key in ("PATH", "HOME", "TMPDIR") if key in os.environ}
    process = subprocess.Popen(command, cwd=output_dir, env=environment, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    output = b""
    try:
        try:
            output, _ = process.communicate(timeout=60)
        except subprocess.TimeoutExpired as error:
            output = error.output or b""
            raise
        if not is_expected_admission_denial(output, process.returncode):
            raise GuardError("admission compiler denial not established")
    finally:
        try:
            if process.poll() is None:
                try:
                    if os.getpgid(process.pid) != process.pid:
                        raise GuardError("probe process identity changed")
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            process.wait(timeout=5)
            try:
                os.killpg(process.pid, 0)
            except ProcessLookupError:
                pass
            else:
                raise GuardError("probe process group survived")
        finally:
            if process.stdout is not None:
                process.stdout.close()
            log_fd = os.open(output_dir / "admission-negative.log", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(log_fd, "wb") as log:
                log.write(output[-262144:])
    if read_regular(probe) != ADMISSION_PROBE or sha(read_regular(declaration_path)) != ADMISSION_SHA256:
        raise GuardError("admission probe input changed")


def run_test(command: list[str], cwd: Path, extra: dict[str, str], result: dict, timeout: int,
             expected_tests: int = 1) -> None:
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
                  "reconciliation-sync", "credential", "create-reconciled", "complete")
        result["stages"] = [stage for stage in stages if ("strict-stage: " + stage).encode() in output]
        error_cases = ("staleAccess", "operationInProgress", "ineligibleCipher", "noMatchingURI",
                       "unsupportedMatch", "cipherUnavailable", "invalidSnapshot", "syncFailed")
        result["knownErrorCases"] = [case for case in error_cases if case.encode() in output]
        result["xctestExitCode"] = process.returncode
        marker = f"Executed {expected_tests} test".encode()
        if process.returncode != 0 or marker not in output or b"with 0 failures" not in output:
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
    verify_package(args.receipt, args.debug_package, "debug", args.sdk_profile)
    if args.sdk_profile == "sdk9":
        verify_service_sources(args.service_primary, args.service_candidate, args.service_patch)
    helper = load_pinned(args.transport_helper, HELPER_SHA256, "strict_transport_helper")
    vector, token, response = public_fixture(args.sdk_source, args.extractor)
    output_name = "NativeBitwardenServiceBackend" if args.sdk_profile == "sdk9" else "NativeBitwardenWriteAuthority"
    base = safe_path(Path(__file__).resolve().parents[1], "build/" + output_name)
    if args.output.parent != base or not args.output.is_absolute() or args.output.exists() or args.output.is_symlink():
        raise GuardError("fresh owned output required")
    base.mkdir(parents=True, exist_ok=True)
    safe_path(Path(__file__).resolve().parents[1], "build/" + output_name)
    if sha(read_regular(Path(__file__).resolve())) != before["scripts/test-native-bitwarden-strict-backend.py"]:
        raise GuardError("running runner differs from checkpoint")
    args.output.mkdir(mode=0o700)
    result["outputCreated"] = True
    package = args.output / "SDKPackage"
    shutil.copytree(args.debug_package, package)
    verify_package(args.receipt, package, "debug", args.sdk_profile)
    harness = args.output / "harness"
    harness.mkdir()
    for name in sorted(INPUTS):
        if not compiled_input(name):
            continue
        destination = harness / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(safe_path(args.source_root, name), destination)
        if sha(read_regular(destination)) != before[name]:
            raise GuardError("staged input mismatch")
    declaration = admission_declaration(read_regular(safe_path(
        args.source_root, "Sources/ArcusisBrowser/NativeBitwardenController.swift")))
    declaration_path = harness / "Sources/ArcusisBrowser/NativeBitwardenControllerAdmission.swift"
    declaration_path.write_bytes(declaration)
    (harness / "Package.swift").write_text(PACKAGE)
    def check_staged():
        for name in INPUTS:
            if compiled_input(name):
                if sha(read_regular(safe_path(harness, name))) != before[name]:
                    raise GuardError("staged source changed")
        if read_regular(harness / "Package.swift") != PACKAGE.encode():
            raise GuardError("harness package changed")
        if read_regular(declaration_path) != declaration:
            raise GuardError("staged admission changed")
        if (sha(read_regular(args.transport_helper)) != HELPER_SHA256
                or sha(read_regular(args.extractor)) != EXTRACTOR_SHA256
                or sha(read_regular(safe_path(args.sdk_source, "crates/bitwarden-core/src/client/test_accounts.rs"))) != VECTOR_SHA256):
            raise GuardError("fixture source changed")
        verify_checkpoint(args.source_root, args.source_manifest, args.source_manifest_sha256)
        verify_package(args.receipt, args.debug_package, "debug", args.sdk_profile)
        verify_package(args.receipt, package, "debug", args.sdk_profile)
        if args.sdk_profile == "sdk9":
            verify_service_sources(args.service_primary, args.service_candidate, args.service_patch)
    check_staged()
    result["phase"] = "admission-negative"
    run_admission_negative(helper, args.output, declaration_path)
    result["unrelatedFileAdmissionDenied"] = True
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
    result["phase"] = "authority-xctest"
    authority_command = ["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny process-fork)(deny network*)",
                         XCTEST, "-XCTest", "BrowserAppTests.NativeBitwardenWriteAuthorityTests", str(bundle)]
    authority_result = {}
    run_test(authority_command, args.output, {}, authority_result, 60, expected_tests=4)
    result["authorityTests"] = "passed"
    check_staged()
    server = helper.Server()
    server.RequestHandlerClass = host_handler(helper, vector, token, response, args.provider_shape)
    server.prelogins = 0
    server.logins = 0
    server.creates = 0
    server.created = None
    server.create_pending = threading.Event()
    server.create_release = threading.Event()
    server.shape_fault = None
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
                   "currentPassword": vector["currentPassword"], "cipherID": CIPHER_ID,
                   "shape": args.provider_shape}
        extra = {"ARCUSIS_STRICT_BACKEND_FIXTURE": base64.b64encode(json.dumps(fixture).encode()).decode()}
        command = ["/usr/bin/sandbox-exec", "-p", helper.runtime_sandbox(address[1]), XCTEST,
                   "-XCTest", "BrowserAppTests.NativeBitwardenStrictBackendTests/testStrictPreparationLifecycle", str(bundle)]
        run_test(command, args.output, extra, result, 90)
    finally:
        server.release.set()
        server.create_release.set()
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
                            "put": server.puts, "create": server.creates,
                            "requests": server.total, "errors": len(server.errors)}
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
    expected_syncs = 9 if args.sdk_profile == "sdk9" else 6
    if (server.errors or server.prelogins != 2 or server.logins != 2 or server.syncs != expected_syncs
            or server.puts != 1 or server.creates != 1):
        raise GuardError("fixture count mismatch")
    if result["testBinarySHA256After"] != binary_hash:
        raise GuardError("test binary changed")
    check_staged()
    result["status"] = "passed"
    result["phase"] = "complete"


def run_legacy(args, result: dict) -> None:
    mode = args.run_legacy
    before = verify_checkpoint(args.source_root, args.source_manifest, args.source_manifest_sha256)
    helper = load_pinned(args.transport_helper, HELPER_SHA256, "strict_transport_legacy_helper")
    if mode != "default":
        verify_legacy_package(args.legacy_package, mode)
    base = safe_path(Path(__file__).resolve().parents[1], "build/NativeBitwardenWriteAuthority")
    if args.output.parent != base or not args.output.is_absolute() or args.output.exists() or args.output.is_symlink():
        raise GuardError("fresh owned output required")
    base.mkdir(parents=True, exist_ok=True)
    safe_path(Path(__file__).resolve().parents[1], "build/NativeBitwardenWriteAuthority")
    if sha(read_regular(Path(__file__).resolve())) != before["scripts/test-native-bitwarden-strict-backend.py"]:
        raise GuardError("running runner differs from checkpoint")
    args.output.mkdir(mode=0o700)
    result["outputCreated"] = True
    package = args.output / "SDKPackage"
    if mode != "default":
        shutil.copytree(args.legacy_package, package)
        verify_legacy_package(package, mode)
    harness = args.output / "harness"
    harness.mkdir()
    for name in sorted(INPUTS):
        if not compiled_input(name):
            continue
        target = harness / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(safe_path(args.source_root, name), target)
    declaration = admission_declaration(read_regular(safe_path(
        args.source_root, "Sources/ArcusisBrowser/NativeBitwardenController.swift")))
    declaration_path = harness / "Sources/ArcusisBrowser/NativeBitwardenControllerAdmission.swift"
    declaration_path.write_bytes(declaration)
    dependency = 'dependencies: [.package(name: "SDKPackage", path: "../SDKPackage")],' if mode != "default" else ""
    product = ', .product(name: "ArcusisBitwardenSDK", package: "SDKPackage")' if mode != "default" else ""
    settings = (', swiftSettings: [.define("ARCUSIS_NATIVE_BITWARDEN_ORGANIZATION_CANDIDATE"), '
                '.define("ARCUSIS_NATIVE_BITWARDEN_REFRESH_CANDIDATE")]') if mode == "sdk7" else ""
    package_text = '''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "ArcusisBrowser", platforms: [.macOS("26.0")],
  DEPENDENCY targets: [
    .target(name: "BrowserCore", resources: [.process("Resources/public_suffix_list.dat")]),
    .target(name: "ArcusisBrowser", dependencies: ["BrowserCore" PRODUCT] SETTINGS),
    .testTarget(name: "BrowserAppTests", dependencies: ["ArcusisBrowser", "BrowserCore" PRODUCT]),
  ])
'''.replace("DEPENDENCY", dependency).replace("PRODUCT", product).replace(" SETTINGS", settings)
    (harness / "Package.swift").write_text(package_text)
    def check_inputs():
        verify_checkpoint(args.source_root, args.source_manifest, args.source_manifest_sha256)
        if sha(read_regular(args.transport_helper)) != HELPER_SHA256:
            raise GuardError("helper changed")
        for name in INPUTS:
            if compiled_input(name):
                if sha(read_regular(safe_path(harness, name))) != before[name]:
                    raise GuardError("staged source changed")
        if read_regular(harness / "Package.swift") != package_text.encode():
            raise GuardError("harness package changed")
        if read_regular(declaration_path) != declaration:
            raise GuardError("staged admission changed")
        if mode != "default":
            verify_legacy_package(args.legacy_package, mode)
            verify_legacy_package(package, mode)
    check_inputs()
    scratch = args.output / "swift-build"
    cache = args.output / "swift-cache"
    cache.mkdir(mode=0o700)
    build = ["/usr/bin/sandbox-exec", "-p", helper.BUILD_SANDBOX, "swift", "build",
             "--package-path", str(harness), "--scratch-path", str(scratch), "--cache-path", str(cache),
             "--build-tests", "--jobs", "2", "--disable-keychain", "--disable-netrc",
             "--disable-dependency-cache", "--disable-prefetching", "--manifest-cache", "none", "--disable-sandbox"]
    if mode != "default":
        build += ["-Xlinker", "-rpath", "-Xlinker", str(package / "Frameworks/BitwardenSDK.xcframework/macos-arm64")]
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
    bundle = bin_dir / "BrowserAppTests.xctest"
    binary = bundle / "Contents/MacOS/BrowserAppTests"
    result["testBinarySHA256Before"] = sha(read_regular(helper.regular(binary)))
    check_inputs()
    result["phase"] = "xctest"
    command = ["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny process-fork)(deny network*)",
               XCTEST, "-XCTest", "BrowserAppTests.NativeBitwardenStrictDefaultTests/testLegacyPathsRemainFailClosedWithoutSession", str(bundle)]
    try:
        run_test(command, args.output, {}, result, 60)
    finally:
        result["testBinarySHA256After"] = sha(read_regular(helper.regular(binary)))
        check_inputs()
    if result["testBinarySHA256After"] != result["testBinarySHA256Before"]:
        raise GuardError("test binary changed")
    result["status"] = "passed"
    result["phase"] = "complete"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--source-manifest", required=True, type=Path)
    parser.add_argument("--source-manifest-sha256", required=True)
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--debug-package", type=Path)
    parser.add_argument("--sdk-profile", choices=("sdk8", "sdk9"), default="sdk8")
    parser.add_argument("--provider-shape", choices=("bitwarden", "vaultwarden"))
    parser.add_argument("--service-primary", type=Path)
    parser.add_argument("--service-candidate", type=Path)
    parser.add_argument("--service-patch", type=Path)
    parser.add_argument("--run-fixture", action="store_true")
    parser.add_argument("--run-legacy", choices=("default", "sdk3", "sdk7"))
    parser.add_argument("--legacy-package", type=Path)
    parser.add_argument("--transport-helper", type=Path)
    parser.add_argument("--sdk-source", type=Path)
    parser.add_argument("--extractor", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.run_legacy:
        if (args.sdk_profile != "sdk8" or args.provider_shape is not None or args.run_fixture or args.transport_helper is None or args.output is None
                or (args.run_legacy != "default" and args.legacy_package is None)
                or (args.run_legacy == "default" and args.legacy_package is not None)):
            parser.error("legacy mode requires helper, fresh output and selected package")
        result = {"status": "incomplete", "phase": "validation", "outputCreated": False,
                  "mode": args.run_legacy, "sourceManifestSHA256": args.source_manifest_sha256,
                  "productAcceptance": False}
        try:
            run_legacy(args, result)
        except BaseException as error:
            result["errorType"] = type(error).__name__
            raise
        finally:
            if result["outputCreated"]:
                try:
                    verify_checkpoint(args.source_root, args.source_manifest, args.source_manifest_sha256)
                    if args.run_legacy != "default":
                        verify_legacy_package(args.legacy_package, args.run_legacy)
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
        print("legacy fail-closed component test passed")
        return
    if args.run_fixture:
        if any(value is None for value in (args.receipt, args.debug_package, args.transport_helper, args.sdk_source, args.extractor, args.output)):
            parser.error("fixture requires transport helper, SDK source, extractor and fresh output")
        if args.sdk_profile == "sdk9" and (args.provider_shape is None or any(
                value is None for value in (args.service_primary, args.service_candidate, args.service_patch))):
            parser.error("SDK9 requires provider shape and pinned service sources")
        if args.sdk_profile == "sdk8" and (args.provider_shape is not None or any(
                value is not None for value in (args.service_primary, args.service_candidate, args.service_patch))):
            parser.error("SDK8 cannot use service-shape inputs")
        result = {"status": "incomplete", "phase": "validation", "outputCreated": False,
                  "sourceManifestSHA256": args.source_manifest_sha256, "productAcceptance": False,
                  "sdkProfile": args.sdk_profile, "providerShape": args.provider_shape}
        try:
            run_backend(args, result)
        except BaseException as error:
            result["errorType"] = type(error).__name__
            raise
        finally:
            if result["outputCreated"]:
                try:
                    verify_checkpoint(args.source_root, args.source_manifest, args.source_manifest_sha256)
                    verify_package(args.receipt, args.debug_package, "debug", args.sdk_profile)
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
    if args.receipt is None or args.debug_package is None:
        parser.error("input verification requires receipt and debug package")
    verify_checkpoint(args.source_root, args.source_manifest, args.source_manifest_sha256)
    verify_package(args.receipt, args.debug_package, "debug", args.sdk_profile)
    print("input checkpoint verified; no fixture was run")


if __name__ == "__main__":
    main()
