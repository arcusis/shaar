#!/usr/bin/env python3
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Verify local engine bundle integrity without changing bundle or trust state."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import selectors
import stat
import subprocess
import sys
import tempfile
import time
from typing import Any
from urllib.parse import urlsplit

SCHEMA_VERSION = 1
SCRIPT_REPO = Path(__file__).resolve().parents[1]
MAX_PIN_BYTES = 64 * 1024
MAX_METADATA_BYTES = 8 * 1024 * 1024
MAX_TOOL_OUTPUT = 32 * 1024
TOOL_TIMEOUT_SECONDS = 30
TOOL_ENV = {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"}
PIN_KEYS = {"repository", "sourceCommit", "sourceTag", "engineTree", "archiveURL", "sha256", "chromiumVersion", "architecture"}
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
APP_ID = "com.arcusis.browser"
APP_EXECUTABLE = "ArcusisBrowser"
FRAMEWORK_ID = "com.ardia.browser.framework"
HELPERS = {
    "Chromium Helper.app": ("com.ardia.browser.helper", "Chromium Helper"),
    "Chromium Helper (GPU).app": ("com.ardia.browser.helper", "Chromium Helper (GPU)"),
    "Chromium Helper (Renderer).app": ("com.ardia.browser.helper.renderer", "Chromium Helper (Renderer)"),
    "Chromium Helper (Alerts).app": ("com.ardia.browser.framework.AlertNotificationService", "Chromium Helper (Alerts)"),
    "Chromium Helper (Aperitif).app": ("com.ardia.browser.helper", "Chromium Helper (Aperitif)"),
    "Chromium Helper (Aperitif GPU).app": ("com.ardia.browser.helper", "Chromium Helper (Aperitif GPU)"),
    "Chromium Helper (Aperitif Renderer).app": ("com.ardia.browser.helper.renderer", "Chromium Helper (Aperitif Renderer)"),
    "Chromium Helper (Aperitif Alerts).app": ("com.ardia.browser.framework.AlertNotificationService", "Chromium Helper (Aperitif Alerts)"),
}


class VerifyError(Exception):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


def _read_regular(path: Path, limit: int, owner: int | None = None) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as error:
        raise VerifyError("input_unavailable_or_unsafe") from error
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_size > limit:
            raise VerifyError("input_not_supported")
        if owner is not None and before.st_uid != owner:
            raise VerifyError("bundle_input_not_user_owned")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            data = stream.read(limit + 1)
        after = os.fstat(fd)
        if len(data) > limit:
            raise VerifyError("input_exceeds_size_limit")
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
            after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns
        ) or len(data) != before.st_size:
            raise VerifyError("input_changed_during_read")
        return data
    finally:
        os.close(fd)


def _hash_regular(path: Path, limit: int, owner: int | None = None) -> str:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(path, flags)
    except OSError as error:
        raise VerifyError("input_unavailable_or_unsafe") from error
    digest = hashlib.sha256()
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_size > limit:
            raise VerifyError("input_not_supported")
        if owner is not None and before.st_uid != owner:
            raise VerifyError("bundle_input_not_user_owned")
        size = 0
        with os.fdopen(fd, "rb", closefd=False) as stream:
            while block := stream.read(1024 * 1024):
                size += len(block)
                if size > limit:
                    raise VerifyError("input_exceeds_size_limit")
                digest.update(block)
        after = os.fstat(fd)
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
            after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns
        ) or size != before.st_size:
            raise VerifyError("input_changed_during_read")
        return digest.hexdigest()
    finally:
        os.close(fd)


def _check_regular(path: Path, limit: int, owner: int | None = None) -> None:
    try:
        info = path.lstat()
    except OSError as error:
        raise VerifyError("input_unavailable_or_unsafe") from error
    if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
        raise VerifyError("input_not_supported")
    if owner is not None and info.st_uid != owner:
        raise VerifyError("bundle_input_not_user_owned")


def _check_dir(path: Path, owner: int) -> None:
    try:
        info = path.lstat()
    except OSError as error:
        raise VerifyError("bundle_structure_invalid") from error
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != owner:
        raise VerifyError("bundle_structure_invalid")


def _stop_process(process: subprocess.Popen) -> None:
    if process.poll() is None:
        try:
            process.kill()
        except OSError:
            pass
    process.wait()


def _load_pin(repo: Path) -> tuple[dict[str, str], bytes]:
    raw = _read_regular(repo / "ThirdParty/ArdiaCore/pin.json", MAX_PIN_BYTES)
    try:
        pin = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise VerifyError("pin_malformed") from error
    if not isinstance(pin, dict) or set(pin) != PIN_KEYS or any(
        not isinstance(pin[key], str) or not pin[key] or len(pin[key]) > 2048 for key in PIN_KEYS
    ):
        raise VerifyError("pin_schema_invalid")
    if not HEX64.fullmatch(pin["sha256"]) or not HEX40.fullmatch(pin["sourceCommit"]) or not HEX40.fullmatch(pin["engineTree"]):
        raise VerifyError("pin_digest_invalid")
    urls = (urlsplit(pin["repository"]), urlsplit(pin["archiveURL"]))
    if any(url.scheme != "https" or not url.hostname or url.username or url.password for url in urls):
        raise VerifyError("pin_url_invalid")
    if (not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,127}", pin["sourceTag"])
            or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", pin["chromiumVersion"])):
        raise VerifyError("pin_version_invalid")
    if pin["architecture"] != "arm64":
        raise VerifyError("pin_architecture_unsupported")
    return pin, raw


def _load_payload_module(repo: Path):
    module_path = repo / "scripts/engine_payload.py"
    spec = importlib.util.spec_from_file_location("_engine_payload_for_verifier", module_path)
    if spec is None or spec.loader is None:
        raise VerifyError("payload_helper_unavailable")
    module = importlib.util.module_from_spec(spec)
    try:
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
    except (OSError, ImportError, SyntaxError) as error:
        raise VerifyError("payload_helper_unavailable") from error
    return module


def _bounded_run(argv: list[str]) -> tuple[int, bytes]:
    try:
        process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env=TOOL_ENV, shell=False, close_fds=True)
    except OSError as error:
        raise VerifyError("codesign_unavailable") from error
    assert process.stdout is not None and process.stderr is not None
    selector = selectors.DefaultSelector()
    output = bytearray()
    try:
        for stream in (process.stdout, process.stderr):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ)
        deadline = time.monotonic() + TOOL_TIMEOUT_SECONDS
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                _stop_process(process)
                raise VerifyError("codesign_timeout")
            for key, _ in selector.select(min(remaining, 0.25)):
                chunk = os.read(key.fileobj.fileno(), 4096)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                if len(output) + len(chunk) > MAX_TOOL_OUTPUT:
                    _stop_process(process)
                    raise VerifyError("codesign_output_exceeds_limit")
                output.extend(chunk)
        returncode = process.wait(timeout=max(0.01, deadline - time.monotonic()))
        return returncode, bytes(output)
    except subprocess.TimeoutExpired as error:
        _stop_process(process)
        raise VerifyError("codesign_timeout") from error
    finally:
        _stop_process(process)
        selector.close()
        process.stdout.close()
        process.stderr.close()


def _codesign(path: Path, operation: str, expected_identifier: str) -> dict[str, str]:
    if operation == "verify":
        argv = ["/usr/bin/codesign", "--verify", "--strict", "--deep", "--verbose=2", str(path)]
    elif operation == "display":
        argv = ["/usr/bin/codesign", "--display", "--verbose=4", str(path)]
    else:
        raise VerifyError("internal_operation_invalid")
    status, raw = _bounded_run(argv)
    if status != 0:
        raise VerifyError("codesign_verification_failed" if operation == "verify" else "codesign_identity_failed")
    if operation == "verify":
        return {"verified": "true"}
    fields: dict[str, str] = {}
    authorities: list[str] = []
    try:
        lines = raw.decode("utf-8", "strict").splitlines()
    except UnicodeError as error:
        raise VerifyError("signature_data_unrecognized") from error
    for line in lines:
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if key == "Authority":
            authorities.append(value)
        elif key in {"Identifier", "TeamIdentifier", "Signature", "CDHash"}:
            if key in fields:
                raise VerifyError("signature_data_contradictory")
            fields[key] = value
    if fields.get("Identifier") != expected_identifier:
        raise VerifyError("signature_identifier_mismatch")
    team = fields.get("TeamIdentifier")
    cdhash = fields.get("CDHash", "").lower()
    if team is None or not re.fullmatch(r"[0-9a-f]{40}", cdhash):
        raise VerifyError("signature_data_unrecognized")
    signature = fields.get("Signature")
    if signature == "adhoc" and team == "not set" and not authorities:
        kind, signer = "adhoc", "adhoc"
    elif signature is None and team != "not set" and len(authorities) == 3:
        first = authorities[0]
        match = re.fullmatch(r"Developer ID Application: .+ \(([A-Z0-9]{10})\)", first)
        if (not match or match.group(1) != team or authorities[1:] !=
                ["Developer ID Certification Authority", "Apple Root CA"]):
            raise VerifyError("signature_data_unrecognized")
        if len(set(authorities)) != 3:
            raise VerifyError("signature_data_contradictory")
        kind = "developer_id"
        signer = hashlib.sha256((team + "\n" + "\n".join(authorities)).encode()).hexdigest()
    else:
        raise VerifyError("signature_data_unrecognized")
    return {"kind": kind, "signer": signer, "cdhash": cdhash}


def _contained_framework_links(framework: Path) -> None:
    expected = {
        "Chromium Framework": "Versions/Current/Chromium Framework",
        "Helpers": "Versions/Current/Helpers",
        "Libraries": "Versions/Current/Libraries",
        "Resources": "Versions/Current/Resources",
    }
    for name, target in expected.items():
        link = framework / name
        try:
            info = link.lstat()
        except OSError as error:
            raise VerifyError("framework_structure_invalid") from error
        if not stat.S_ISLNK(info.st_mode) or os.readlink(link) != target:
            raise VerifyError("framework_structure_invalid")
        resolved = link.resolve(strict=True)
        if not resolved.is_relative_to(framework.resolve(strict=True)):
            raise VerifyError("framework_link_escapes")
    current = framework / "Versions/Current"
    try:
        current_info = current.lstat()
        version = os.readlink(current)
    except OSError as error:
        raise VerifyError("framework_structure_invalid") from error
    if not stat.S_ISLNK(current_info.st_mode) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){2,3}", version):
        raise VerifyError("framework_structure_invalid")
    if not (framework / "Versions" / version).is_dir():
        raise VerifyError("framework_structure_invalid")


def _check_bundle_tree(app: Path, framework: Path, owner: int) -> None:
    framework_root = framework.resolve(strict=True)
    for parent, directories, files in os.walk(app, followlinks=False):
        for name in directories + files:
            path = Path(parent) / name
            try:
                info = path.lstat()
            except OSError as error:
                raise VerifyError("bundle_structure_invalid") from error
            if info.st_uid != owner:
                raise VerifyError("bundle_input_not_user_owned")
            if stat.S_ISLNK(info.st_mode):
                try:
                    path.resolve(strict=True).relative_to(framework_root)
                except (OSError, ValueError) as error:
                    raise VerifyError("bundle_link_escapes") from error
            elif not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
                raise VerifyError("bundle_input_not_regular")


def _bundle_metadata(app: Path) -> tuple[Path, Path, list[tuple[Path, str]]]:
    owner = os.getuid()
    try:
        app_info = app.lstat()
    except OSError as error:
        raise VerifyError("bundle_unavailable") from error
    if not stat.S_ISDIR(app_info.st_mode) or app_info.st_uid != owner:
        raise VerifyError("bundle_not_user_owned")
    contents = app / "Contents"
    _check_dir(contents, owner)
    _check_dir(contents / "MacOS", owner)
    _check_dir(contents / "Resources", owner)
    plist_path = contents / "Info.plist"
    plist_raw = _read_regular(plist_path, MAX_METADATA_BYTES, owner)
    try:
        info = plistlib.loads(plist_raw)
    except (plistlib.InvalidFileException, ValueError) as error:
        raise VerifyError("bundle_plist_invalid") from error
    if info.get("CFBundleIdentifier") != APP_ID or info.get("CFBundleExecutable") != APP_EXECUTABLE:
        raise VerifyError("bundle_identity_mismatch")
    executable = contents / "MacOS" / APP_EXECUTABLE
    _check_regular(executable, 512 * 1024 * 1024, owner)
    framework = app / "Contents/Frameworks/Chromium Framework.framework"
    _check_dir(contents / "Frameworks", owner)
    framework_info = framework.lstat()
    if not stat.S_ISDIR(framework_info.st_mode) or framework_info.st_uid != owner:
        raise VerifyError("framework_structure_invalid")
    _contained_framework_links(framework)
    _check_bundle_tree(app, framework, owner)
    versioned = framework / "Versions" / os.readlink(framework / "Versions/Current")
    framework_plist = _read_regular(versioned / "Resources/Info.plist", MAX_METADATA_BYTES, owner)
    try:
        engine_info = plistlib.loads(framework_plist)
    except (plistlib.InvalidFileException, ValueError) as error:
        raise VerifyError("framework_plist_invalid") from error
    if engine_info.get("CFBundleIdentifier") != FRAMEWORK_ID:
        raise VerifyError("framework_identity_mismatch")
    helper_root = versioned / "Helpers"
    _check_dir(versioned, owner)
    _check_dir(helper_root, owner)
    helper_paths: list[tuple[Path, str]] = []
    actual = {p.name for p in helper_root.iterdir() if p.name.endswith(".app")}
    if actual != set(HELPERS):
        raise VerifyError("helper_set_mismatch")
    for name, (identifier, executable_name) in sorted(HELPERS.items()):
        helper = helper_root / name
        _check_dir(helper, owner)
        _check_dir(helper / "Contents", owner)
        _check_dir(helper / "Contents/MacOS", owner)
        helper_info = _read_regular(helper / "Contents/Info.plist", MAX_METADATA_BYTES, owner)
        try:
            values = plistlib.loads(helper_info)
        except (plistlib.InvalidFileException, ValueError) as error:
            raise VerifyError("helper_plist_invalid") from error
        if (values.get("CFBundleIdentifier"), values.get("CFBundleExecutable")) != (identifier, executable_name):
            raise VerifyError("helper_identity_mismatch")
        _check_regular(helper / "Contents/MacOS" / executable_name, 512 * 1024 * 1024, owner)
        helper_paths.append((helper, identifier))
    return framework, executable, helper_paths


def _base_report() -> dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION, "verification": "failed", "reason": "verification_not_completed",
        "inputPinVerified": False, "packagedLicensesVerified": False, "archivePinVerified": False,
        "bundleIdentityVerified": False, "payloadMatch": False, "signatureVerified": False,
        "signatureKind": "unverified", "signatureIdentitiesSha256": {},
        "signatureIdentitySha256": None,
        "sourceProvenanceVerified": False, "notarizationVerified": False, "releaseReady": False,
        "pinSha256": None, "licenseSha256": {}, "archiveSha256": None,
        "payload": {"memberCount": 0, "mismatchCount": 0, "sha256": None},
    }


def verify(repo: Path, app: Path, archive: Path) -> dict[str, Any]:
    report = _base_report()
    try:
        pin, pin_raw = _load_pin(repo)
        report["pinSha256"] = hashlib.sha256(pin_raw).hexdigest()
        packaged = app / "Contents/Resources/ArdiaCore"
        _check_dir(packaged, os.getuid())
        if _read_regular(packaged / "pin.json", MAX_PIN_BYTES, os.getuid()) != pin_raw:
            raise VerifyError("packaged_pin_mismatch")
        report["inputPinVerified"] = True
        license_hashes: dict[str, str] = {}
        license_bytes: dict[str, bytes] = {}
        for name in ("LICENSE", "NOTICE"):
            source = _read_regular(repo / "ThirdParty/ArdiaCore" / name, MAX_METADATA_BYTES)
            bundle = _read_regular(packaged / name, MAX_METADATA_BYTES, os.getuid())
            if source != bundle:
                raise VerifyError("packaged_license_mismatch")
            license_bytes[name] = source
            license_hashes[name] = hashlib.sha256(source).hexdigest()
        report["licenseSha256"] = dict(sorted(license_hashes.items()))
        report["packagedLicensesVerified"] = True
        framework, executable, helpers = _bundle_metadata(app)
        report["bundleIdentityVerified"] = True
        payload_module = _load_payload_module(repo)
        archive_hash = _hash_regular(archive, payload_module.MAX_ARCHIVE_SIZE, os.getuid())
        report["archiveSha256"] = archive_hash
        if archive_hash != pin["sha256"]:
            raise VerifyError("archive_pin_mismatch")
        report["archivePinVerified"] = True
        signed = [(app, APP_ID), (framework, FRAMEWORK_ID), *helpers]
        identity_hashes: dict[str, str] = {}
        kinds: set[str] = set()
        signer_hashes: set[str] = set()
        for path, identifier in signed:
            _codesign(path, "verify", identifier)
            identity = _codesign(path, "display", identifier)
            kinds.add(identity["kind"])
            signer_hashes.add(identity["signer"])
            identity_hashes[identifier + ":" + path.name] = hashlib.sha256(
                (identity["kind"] + "\n" + identifier + "\n" + identity["signer"] + "\n" + identity["cdhash"]).encode()
            ).hexdigest()
        if len(kinds) != 1 or len(signer_hashes) != 1:
            raise VerifyError("signature_identity_mismatch")
        report["signatureIdentitiesSha256"] = dict(sorted(identity_hashes.items()))
        report["signatureKind"] = next(iter(kinds))
        report["signatureVerified"] = True
        report["signatureIdentitySha256"] = hashlib.sha256(json.dumps(
            report["signatureIdentitiesSha256"], sort_keys=True, separators=(",", ":")
        ).encode()).hexdigest()
        payload = payload_module.compare_payload(archive, framework, pin)
        members = payload.get("members", [])
        report["payload"] = {"memberCount": len(members), "mismatchCount": sum(
            item.get("status") != "match" for item in members
        )}
        payload_identity = [{key: item[key] for key in sorted(item) if key in {
            "path", "status", "archive_kind", "framework_kind", "archive_target", "framework_target",
            "archive_sha256", "framework_sha256", "archive_size", "framework_size", "normalization",
        }} for item in members]
        report["payload"]["sha256"] = hashlib.sha256(json.dumps(
            payload_identity, sort_keys=True, separators=(",", ":")
        ).encode()).hexdigest()
        report["payloadMatch"] = bool(payload.get("archive_metadata_verified") and payload.get("payload_match"))
        if not report["payloadMatch"]:
            raise VerifyError("payload_mismatch")
        # Bind source inputs again after all external tools and payload parsing.
        if hashlib.sha256(_read_regular(repo / "ThirdParty/ArdiaCore/pin.json", MAX_PIN_BYTES)).hexdigest() != report["pinSha256"]:
            raise VerifyError("input_changed_during_verification")
        if _read_regular(packaged / "pin.json", MAX_PIN_BYTES, os.getuid()) != pin_raw:
            raise VerifyError("input_changed_during_verification")
        for name, original in license_bytes.items():
            if (_read_regular(repo / "ThirdParty/ArdiaCore" / name, MAX_METADATA_BYTES) != original
                    or _read_regular(packaged / name, MAX_METADATA_BYTES, os.getuid()) != original):
                raise VerifyError("input_changed_during_verification")
        if _hash_regular(archive, payload_module.MAX_ARCHIVE_SIZE, os.getuid()) != archive_hash:
            raise VerifyError("input_changed_during_verification")
        report["verification"] = "passed"
        report["reason"] = "integrity_verified"
    except VerifyError as error:
        report["reason"] = error.code
    except Exception:
        report["reason"] = "verification_input_invalid"
    return report


def _atomic_report(path: Path, report: dict[str, Any], inputs: list[Path]) -> None:
    absolute = Path(os.path.abspath(path))
    for candidate in [*absolute.parents, absolute]:
        try:
            info = candidate.lstat()
        except FileNotFoundError:
            continue
        except OSError as error:
            raise VerifyError("report_path_unsafe") from error
        if stat.S_ISLNK(info.st_mode) and candidate != Path("/var"):
            raise VerifyError("report_path_unsafe")
    if not absolute.parent.is_dir():
        raise VerifyError("report_path_unsafe")
    for source in inputs:
        source_abs = Path(os.path.abspath(source))
        if absolute == source_abs or source_abs in absolute.parents:
            raise VerifyError("report_overlaps_input")
    data = (json.dumps(report, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode()
    fd, temporary = tempfile.mkstemp(prefix=".engine-bundle-report-", dir=absolute.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as stream:
            fd = -1
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        if absolute.exists() and not stat.S_ISREG(absolute.lstat().st_mode):
            raise VerifyError("report_path_unsafe")
        os.replace(temporary, absolute)
        temporary = ""
    except OSError as error:
        raise VerifyError("report_write_failed") from error
    finally:
        if fd >= 0:
            os.close(fd)
        if temporary:
            try:
                os.unlink(temporary)
            except OSError:
                pass


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args(argv)
    report = verify(SCRIPT_REPO, args.app, args.archive)
    if args.report:
        inputs = [SCRIPT_REPO / "ThirdParty/ArdiaCore/pin.json", SCRIPT_REPO / "ThirdParty/ArdiaCore/LICENSE",
                  SCRIPT_REPO / "ThirdParty/ArdiaCore/NOTICE", args.archive, args.app]
        try:
            _atomic_report(args.report, report, inputs)
        except VerifyError as error:
            report = _base_report()
            report["reason"] = error.code
    print(json.dumps(report, sort_keys=True, separators=(",", ":"), ensure_ascii=True))
    return 0 if report["verification"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
