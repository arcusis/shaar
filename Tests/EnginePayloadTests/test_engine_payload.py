# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import hashlib
import importlib.util
import io
import json
import plistlib
from pathlib import Path
import struct
import shutil
import tarfile
import tempfile
import unittest
from unittest import mock


MODULE = Path(__file__).resolve().parents[2] / "scripts/engine_payload.py"
spec = importlib.util.spec_from_file_location("engine_payload", MODULE)
payload = importlib.util.module_from_spec(spec)
spec.loader.exec_module(payload)


FRAMEWORK = "Chromium Framework.framework"


def macho(signature_size=24, code=b"verified code"):
    text_size = 72
    linkedit_size = 72
    signature_command_size = 16
    commands_size = text_size + linkedit_size + signature_command_size
    signature_offset = 256
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, payload.CPU_TYPE_ARM64, 0, 6, 3,
                         commands_size, 0, 0)

    def segment(name, fileoff, filesize):
        name_field = name.encode().ljust(16, b"\0")
        vmsize = (filesize + payload.PAGE_SIZE_ARM64 - 1) & ~(payload.PAGE_SIZE_ARM64 - 1)
        maxprot, initprot = (1, 1) if name == "__LINKEDIT" else (7, 5)
        return struct.pack("<II16sQQQQiiII", payload.LC_SEGMENT_64, 72, name_field,
                           0, vmsize, fileoff, filesize, maxprot, initprot, 0, 0)

    text = segment("__TEXT", 0, signature_offset)
    linkedit = segment("__LINKEDIT", signature_offset, signature_size)
    signature = struct.pack("<IIII", payload.LC_CODE_SIGNATURE, 16,
                            signature_offset, signature_size)
    prefix = header + text + linkedit + signature + code
    prefix += b"\0" * (signature_offset - len(prefix))
    blob = (b"S" * signature_size)
    return prefix + blob


def write_archive(path, members):
    with tarfile.open(path, "w:xz", format=tarfile.PAX_FORMAT) as tar:
        for name, kind, value in members:
            info = tarfile.TarInfo(name)
            if kind == "directory":
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                tar.addfile(info)
            elif kind == "symlink":
                info.type = tarfile.SYMTYPE
                info.linkname = value
                tar.addfile(info)
            elif kind == "hardlink":
                info.type = tarfile.LNKTYPE
                info.linkname = value
                tar.addfile(info)
            else:
                info.size = len(value)
                info.mode = 0o755 if name.endswith("Chromium Framework") else 0o644
                tar.addfile(info, io.BytesIO(value))


class EnginePayloadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="engine-payload-fixture-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / "archive.tar.xz"
        self.framework = self.root / FRAMEWORK
        self.framework.mkdir()

    def fixture(self, files=None, links=None, extra_archive=()):
        if self.framework.exists():
            shutil.rmtree(self.framework)
        self.framework.mkdir()
        files = files or {"Chromium Framework": b"engine", "Resources/helper.dat": b"resource",
                          "Helpers/Browser Helper": b"helper"}
        links = links or {"Versions/Current": "A"}
        members = [(FRAMEWORK, "directory", None)]
        for path in sorted(files):
            members.append((f"{FRAMEWORK}/{path}", "file", files[path]))
        for path in sorted(links):
            members.append((f"{FRAMEWORK}/{path}", "symlink", links[path]))
        members.extend(extra_archive)
        write_archive(self.archive, members)
        for path, data in files.items():
            target = self.framework / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        for path, link in links.items():
            target = self.framework / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.symlink_to(link)
        digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        return payload.compare_payload(self.archive, self.framework, {"sha256": digest})

    def replacement_archive(self, files=None, links=None):
        replacement = self.root / "replacement.tar.xz"
        files = files or {"Chromium Framework": b"substituted engine", "Resources/helper.dat": b"resource",
                          "Helpers/Browser Helper": b"helper"}
        links = links or {"Versions/Current": "A"}
        members = [(FRAMEWORK, "directory", None)]
        for path in sorted(files):
            members.append((f"{FRAMEWORK}/{path}", "file", files[path]))
        for path in sorted(links):
            members.append((f"{FRAMEWORK}/{path}", "symlink", links[path]))
        write_archive(replacement, members)
        for path, data in files.items():
            target = self.framework / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        return replacement

    def test_exact_bytes_and_complete_inventory_match(self):
        report = self.fixture()
        self.assertTrue(report["archive_metadata_verified"])
        self.assertTrue(report["payload_match"])
        self.assertTrue(report["source_provenance_unverified"])
        self.assertTrue(report["signature_verification_not_performed"])
        self.assertEqual(report["members"][0]["path"], "Chromium Framework")
        self.assertNotIn(str(self.root), json.dumps(report))

    def test_terminal_adhoc_signature_changes_normalize(self):
        files = {"Chromium Framework": macho(24)}
        report = self.fixture(files=files, links={})
        replacement = macho(40)
        (self.framework / "Chromium Framework").write_bytes(replacement)
        report = payload.compare_payload(self.archive, self.framework,
                                         {"sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()})
        self.assertTrue(report["payload_match"], report["reason"])
        self.assertEqual(report["members"][0]["normalization"], "adhoc_macho_signature")

    def test_changed_code_resource_and_helper_fail(self):
        cases = (("Chromium Framework", "other code"),
                 ("Resources/helper.dat", b"changed resource"),
                 ("Helpers/Browser Helper", b"changed helper"))
        for path, changed in cases:
            with self.subTest(path=path):
                self.fixture()
                target = self.framework / path
                target.write_bytes(changed.encode() if isinstance(changed, str) else changed)
                report = payload.compare_payload(self.archive, self.framework,
                    {"sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()})
                self.assertFalse(report["payload_match"])

    def test_code_resources_difference_remains_failure(self):
        path = "Versions/155.0.8059.84/_CodeSignature/CodeResources"
        envelope = {"files": {}, "files2": {"Resources/resource": {"hash2": b"original"}},
                    "rules": {}, "rules2": {}}
        self.fixture(files={"Chromium Framework": b"engine",
                            path: plistlib.dumps(envelope, fmt=plistlib.FMT_BINARY)}, links={})
        envelope["files2"]["Resources/resource"]["hash2"] = b"changed"
        (self.framework / path).write_bytes(plistlib.dumps(envelope, fmt=plistlib.FMT_BINARY))
        report = payload.compare_payload(self.archive, self.framework,
            {"sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()})
        self.assertTrue(report["archive_metadata_verified"])
        self.assertFalse(report["payload_match"])
        self.assertEqual(next(item for item in report["members"] if item["path"] == path)["status"],
                         "mismatch")

    def test_codesign_resources_normalizes_only_signature_envelope_for_matched_macho(self):
        version = "Versions/155.0.8059.84"
        helper = "Helpers/app_mode_loader"
        dylib = "Libraries/libsample.dylib"
        resource = "Resources/helper.dat"
        code_resources = f"{version}/_CodeSignature/CodeResources"
        original_envelope = {
            "files": {resource: {"hash": b"resource-seal"}},
            "files2": {
                helper: {"cdhash": b"old-cdhash", "requirement": "old requirement"},
                dylib: {"hash2": b"old-dylib-seal"},
                resource: {"hash2": b"resource-seal"},
            },
            "rules": {"^.*": True},
            "rules2": {"^.*": True},
        }
        files = {
            f"{version}/Chromium Framework": macho(24),
            f"{version}/{helper}": macho(24),
            f"{version}/{dylib}": macho(24),
            f"{version}/{resource}": b"resource",
            code_resources: plistlib.dumps(original_envelope, fmt=plistlib.FMT_BINARY),
        }
        self.fixture(files=files, links={})
        changed = dict(original_envelope)
        changed["files2"] = {path: dict(entry) for path, entry in original_envelope["files2"].items()}
        changed["files2"][helper].update({"cdhash": b"new-cdhash", "requirement": "new requirement"})
        changed["files2"][dylib]["hash2"] = b"new-dylib-seal"
        (self.framework / f"{version}/{helper}").write_bytes(macho(40))
        (self.framework / f"{version}/{dylib}").write_bytes(macho(40))
        (self.framework / code_resources).write_bytes(plistlib.dumps(changed, fmt=plistlib.FMT_BINARY))
        report = payload.compare_payload(self.archive, self.framework,
            {"sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()})
        self.assertTrue(report["payload_match"], report["reason"])
        code_item = next(item for item in report["members"] if item["path"] == code_resources)
        self.assertEqual(code_item["normalization"], "codesign_resources_signing_envelope")
        self.assertNotEqual(code_item["archive_sha256"], code_item["framework_sha256"])
        self.assertTrue(report["source_provenance_unverified"])
        self.assertTrue(report["signature_verification_not_performed"])

    def test_codesign_bundle_seal_maps_only_through_exact_info_plist_and_executable(self):
        version = "Versions/155.0.8059.84"
        app = "Helpers/Browser Helper.app"
        executable = "Browser Helper"
        resources = f"{version}/_CodeSignature/CodeResources"
        app_info = f"{version}/{app}/Contents/Info.plist"
        app_executable = f"{version}/{app}/Contents/MacOS/{executable}"
        raw_path = "Resources/app.icns"
        envelope = {
            "files": {raw_path: hashlib.sha1(b"icon").digest()},
            "files2": {app: {"cdhash": b"old-cdhash", "requirement": "old requirement"}},
            "rules": {}, "rules2": {},
        }
        files = {
            f"{version}/Chromium Framework": macho(24),
            app_info: plistlib.dumps({"CFBundleExecutable": executable}),
            app_executable: macho(24),
            f"{version}/{raw_path}": b"icon",
            resources: plistlib.dumps(envelope, fmt=plistlib.FMT_BINARY),
        }
        self.fixture(files=files, links={})
        changed = {**envelope, "files2": {app: {"cdhash": b"new-cdhash", "requirement": "new requirement"}}}
        (self.framework / app_executable).write_bytes(macho(40))
        (self.framework / resources).write_bytes(plistlib.dumps(changed, fmt=plistlib.FMT_BINARY))
        report = payload.compare_payload(self.archive, self.framework,
            {"sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()})
        self.assertTrue(report["payload_match"], report["reason"])
        code_item = next(item for item in report["members"] if item["path"] == resources)
        self.assertEqual(code_item["normalization"], "codesign_resources_signing_envelope")
        self.assertNotEqual(code_item["archive_sha256"], code_item["framework_sha256"])

        self.fixture(files=files, links={})
        (self.framework / app_executable).write_bytes(macho(40, code=b"changed executable"))
        (self.framework / resources).write_bytes(plistlib.dumps(changed, fmt=plistlib.FMT_BINARY))
        report = payload.compare_payload(self.archive, self.framework,
            {"sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()})
        self.assertFalse(report["payload_match"])

    def test_codesign_resources_rejects_identical_malformed_files2_schema(self):
        path = "Versions/155.0.8059.84/_CodeSignature/CodeResources"
        cases = (
            {"Resources/item": {"hash2": "not-bytes"}},
            {"../escape": {"hash2": b"hash"}},
            {"Resources/item": {"unknown": b"field"}},
        )
        for files2 in cases:
            with self.subTest(files2=files2):
                envelope = {"files": {}, "files2": files2, "rules": {}, "rules2": {}}
                self.fixture(files={"Chromium Framework": b"engine",
                                    path: plistlib.dumps(envelope, fmt=plistlib.FMT_BINARY)}, links={})
                report = payload.compare_payload(self.archive, self.framework,
                    {"sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()})
                self.assertFalse(report["payload_match"])
                self.assertIn("CodeResources", report["reason"])

    def test_codesign_resources_rejects_files2_known_field_additions_and_removals(self):
        version = "Versions/155.0.8059.84"
        helper = "Helpers/app_mode_loader"
        code_resources = f"{version}/_CodeSignature/CodeResources"
        original = {"files": {}, "files2": {helper: {"cdhash": b"old-cdhash",
                                                        "requirement": "old requirement"}},
                    "rules": {}, "rules2": {}}
        mutations = {
            "add optional": lambda entry: entry.update(optional=True),
            "add hash2": lambda entry: entry.update(hash2=b"new hash"),
            "remove cdhash": lambda entry: entry.pop("cdhash"),
            "remove requirement": lambda entry: entry.pop("requirement"),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                files = {
                    f"{version}/Chromium Framework": macho(24),
                    f"{version}/{helper}": macho(24),
                    code_resources: plistlib.dumps(original, fmt=plistlib.FMT_BINARY),
                }
                self.fixture(files=files, links={})
                changed_entry = dict(original["files2"][helper])
                mutate(changed_entry)
                changed = {**original, "files2": {helper: changed_entry}}
                (self.framework / f"{version}/{helper}").write_bytes(macho(40))
                (self.framework / code_resources).write_bytes(
                    plistlib.dumps(changed, fmt=plistlib.FMT_BINARY))
                report = payload.compare_payload(self.archive, self.framework,
                    {"sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()})
                self.assertFalse(report["payload_match"], report["reason"])
                code_item = next(item for item in report["members"] if item["path"] == code_resources)
                self.assertEqual(code_item["status"], "mismatch")

    def test_codesign_bundle_seal_rejects_changed_nested_executable_binding(self):
        version = "Versions/155.0.8059.84"
        app = "Helpers/Browser Helper.app"
        executable = "Browser Helper"
        resources = f"{version}/_CodeSignature/CodeResources"
        info = f"{version}/{app}/Contents/Info.plist"
        executable_path = f"{version}/{app}/Contents/MacOS/{executable}"
        envelope = {"files": {}, "files2": {app: {"cdhash": b"old-cdhash"}},
                    "rules": {}, "rules2": {}}
        files = {
            f"{version}/Chromium Framework": macho(24),
            info: plistlib.dumps({"CFBundleExecutable": executable}),
            executable_path: macho(24),
            resources: plistlib.dumps(envelope, fmt=plistlib.FMT_BINARY),
        }
        self.fixture(files=files, links={})
        (self.framework / info).write_bytes(plistlib.dumps({"CFBundleExecutable": "Other"}))
        changed = {**envelope, "files2": {app: {"cdhash": b"new-cdhash"}}}
        (self.framework / executable_path).write_bytes(macho(40))
        (self.framework / resources).write_bytes(plistlib.dumps(changed, fmt=plistlib.FMT_BINARY))
        report = payload.compare_payload(self.archive, self.framework,
            {"sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()})
        self.assertFalse(report["payload_match"], report["reason"])
        code_item = next(item for item in report["members"] if item["path"] == resources)
        self.assertEqual(code_item["status"], "mismatch")

    def test_codesign_bundle_seal_rejects_added_or_missing_helper_payload(self):
        version = "Versions/155.0.8059.84"
        helper = "Helpers/app_mode_loader"
        resources = f"{version}/_CodeSignature/CodeResources"
        envelope = {"files": {}, "files2": {helper: {"cdhash": b"old-cdhash"}},
                    "rules": {}, "rules2": {}}
        files = {
            f"{version}/Chromium Framework": macho(24),
            f"{version}/{helper}": macho(24),
            resources: plistlib.dumps(envelope, fmt=plistlib.FMT_BINARY),
        }
        for change in ("added", "missing"):
            with self.subTest(change=change):
                self.fixture(files=files, links={})
                changed = {**envelope, "files2": {helper: {"cdhash": b"new-cdhash"}}}
                (self.framework / f"{version}/{helper}").write_bytes(macho(40))
                if change == "added":
                    (self.framework / f"{version}/Helpers/extra_helper").write_bytes(b"extra helper")
                else:
                    (self.framework / f"{version}/{helper}").unlink()
                (self.framework / resources).write_bytes(plistlib.dumps(changed, fmt=plistlib.FMT_BINARY))
                report = payload.compare_payload(self.archive, self.framework,
                    {"sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()})
                self.assertFalse(report["payload_match"], report["reason"])

    def test_codesign_resources_raw_v1_sha1_change_remains_failure(self):
        path = "Versions/155.0.8059.84/_CodeSignature/CodeResources"
        envelope = {"files": {"Resources/item": hashlib.sha1(b"old").digest()},
                    "files2": {}, "rules": {}, "rules2": {}}
        self.fixture(files={"Chromium Framework": b"engine",
                            path: plistlib.dumps(envelope, fmt=plistlib.FMT_BINARY)}, links={})
        envelope["files"]["Resources/item"] = hashlib.sha1(b"new").digest()
        (self.framework / path).write_bytes(plistlib.dumps(envelope, fmt=plistlib.FMT_BINARY))
        report = payload.compare_payload(self.archive, self.framework,
            {"sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()})
        self.assertFalse(report["payload_match"])
        self.assertEqual(next(item for item in report["members"] if item["path"] == path)["status"], "mismatch")

    def test_codesign_envelope_edit_cannot_hide_non_signature_macho_tamper(self):
        version = "Versions/155.0.8059.84"
        helper = "Helpers/app_mode_loader"
        resources = f"{version}/_CodeSignature/CodeResources"
        envelope = {"files": {}, "files2": {helper: {"cdhash": b"old"}},
                    "rules": {}, "rules2": {}}
        self.fixture(files={f"{version}/Chromium Framework": macho(24, code=b"original"),
                            f"{version}/{helper}": macho(24),
                            resources: plistlib.dumps(envelope, fmt=plistlib.FMT_BINARY)}, links={})
        envelope["files2"][helper]["cdhash"] = b"new"
        (self.framework / f"{version}/{helper}").write_bytes(macho(40, code=b"tampered"))
        (self.framework / resources).write_bytes(plistlib.dumps(envelope, fmt=plistlib.FMT_BINARY))
        report = payload.compare_payload(self.archive, self.framework,
            {"sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()})
        self.assertFalse(report["payload_match"])
        self.assertTrue(any(item["path"] == f"{version}/{helper}" and item["status"] == "mismatch"
                            for item in report["members"]))

    def test_codesign_resources_rejects_non_signature_envelope_changes(self):
        version = "Versions/155.0.8059.84"
        helper = "Helpers/app_mode_loader"
        code_resources = f"{version}/_CodeSignature/CodeResources"
        original = {
            "files": {"Resources/helper.dat": {"hash": b"resource-seal"}},
            "files2": {helper: {"cdhash": b"old", "requirement": "old"},
                       "Resources/helper.dat": {"hash2": b"resource-seal"}},
            "rules": {"^.*": True},
            "rules2": {"^.*": True},
        }
        mutations = {
            "files seal": lambda data: data["files"]["Resources/helper.dat"].update(hash=b"changed"),
            "rules": lambda data: data.update(rules={"^.*": False}),
            "rules2": lambda data: data.update(rules2={"^.*": False}),
            "unknown root key": lambda data: data.update(extra=True),
            "unknown signing field": lambda data: data["files2"][helper].update(team=b"unknown"),
            "unknown files field": lambda data: data["files"]["Resources/helper.dat"].update(team=b"unknown"),
            "unknown path": lambda data: data["files2"].update({"Resources/other": {"cdhash": b"x"}}),
            "non-code seal": lambda data: data["files2"][helper].update(hash=b"changed"),
            "resource seal": lambda data: data["files2"]["Resources/helper.dat"].update(hash2=b"changed"),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                files = {
                    f"{version}/Chromium Framework": macho(24),
                    f"{version}/{helper}": macho(24),
                    f"{version}/Resources/helper.dat": b"resource",
                    code_resources: plistlib.dumps(original, fmt=plistlib.FMT_BINARY),
                }
                self.fixture(files=files, links={})
                changed = {key: value.copy() if isinstance(value, dict) else value for key, value in original.items()}
                changed["files"] = {key: dict(value) for key, value in original["files"].items()}
                changed["files2"] = {key: dict(value) for key, value in original["files2"].items()}
                mutate(changed)
                (self.framework / f"{version}/{helper}").write_bytes(macho(40))
                (self.framework / code_resources).write_bytes(plistlib.dumps(changed, fmt=plistlib.FMT_BINARY))
                report = payload.compare_payload(self.archive, self.framework,
                    {"sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()})
                self.assertFalse(report["payload_match"], report["reason"])

    def test_codesign_resources_rejects_malformed_and_oversized_plists(self):
        path = "Versions/155.0.8059.84/_CodeSignature/CodeResources"
        cases = ((b"not a plist", b"not a plist"),
                 (b"not a plist", b"different malformed plist"),
                 (b"x" * (payload.MAX_CODE_RESOURCES_SIZE + 1),
                  b"x" * (payload.MAX_CODE_RESOURCES_SIZE + 1)))
        for archive_data, framework_data in cases:
            with self.subTest(size=len(archive_data), equal=archive_data == framework_data):
                self.fixture(files={"Chromium Framework": b"engine", path: archive_data}, links={})
                (self.framework / path).write_bytes(framework_data)
                report = payload.compare_payload(self.archive, self.framework,
                    {"sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()})
                self.assertFalse(report["payload_match"])

    def test_resigning_cannot_hide_changed_macho_code(self):
        self.fixture(files={"Chromium Framework": macho(24, code=b"original code")}, links={})
        (self.framework / "Chromium Framework").write_bytes(macho(40, code=b"changed code"))
        report = payload.compare_payload(self.archive, self.framework,
            {"sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()})
        self.assertTrue(report["archive_metadata_verified"])
        self.assertFalse(report["payload_match"])
        self.assertEqual(report["members"][0]["status"], "mismatch")

    def test_missing_and_extra_inventory_fail(self):
        self.fixture()
        (self.framework / "Resources/helper.dat").unlink()
        (self.framework / "Extra").write_bytes(b"extra")
        report = payload.compare_payload(self.archive, self.framework,
            {"sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()})
        self.assertFalse(report["payload_match"])
        statuses = {entry["status"] for entry in report["members"]}
        self.assertIn("missing_framework_member", statuses)
        self.assertIn("extra_framework_member", statuses)

    def test_unsafe_paths_duplicate_paths_and_unsupported_links_fail(self):
        cases = [
            [("../escape", "file", b"bad")],
            [(f"{FRAMEWORK}/Chromium Framework", "file", b"one"),
             (f"{FRAMEWORK}/Chromium Framework", "file", b"two")],
            [(f"{FRAMEWORK}/hard", "hardlink", "target")],
            [(f"{FRAMEWORK}/bad", "symlink", "../../escape")],
        ]
        for extra in cases:
            with self.subTest(extra=extra):
                members = [(FRAMEWORK, "directory", None),
                           (f"{FRAMEWORK}/Chromium Framework", "file", b"engine"), *extra]
                write_archive(self.archive, members)
                report = payload.compare_payload(self.archive, self.framework,
                    {"sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()})
                self.assertFalse(report["archive_metadata_verified"])
                self.assertFalse(report["payload_match"])

    def test_malformed_signature_commands_and_unsupported_formats_fail_closed(self):
        for mutation in ("nonterminal", "bad_commands", "bad_segment", "unsafe_linkedit", "fat"):
            with self.subTest(mutation=mutation):
                source = bytearray(macho())
                if mutation == "nonterminal":
                    struct.pack_into("<I", source, 32 + 72 + 72 + 8, 200)
                elif mutation == "bad_commands":
                    struct.pack_into("<I", source, 32 + 72, 7)
                elif mutation == "bad_segment":
                    struct.pack_into("<Q", source, 32 + 72 + 48, 23)
                elif mutation == "unsafe_linkedit":
                    struct.pack_into("<i", source, 32 + 72 + 60, 5)
                else:
                    source[:4] = b"\xca\xfe\xba\xbe"
                self.fixture(files={"Chromium Framework": bytes(source)}, links={})
                report = payload.compare_payload(self.archive, self.framework,
                    {"sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()})
                target = self.framework / "Chromium Framework"
                target.write_bytes(bytes(source))
                report = payload.compare_payload(self.archive, self.framework,
                    {"sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()})
                self.assertFalse(report["payload_match"])
                self.assertIsNotNone(report["reason"])

    def test_exact_malformed_macho_and_overlapping_segments_fail_closed(self):
        cases = ("truncated_commands", "overlapping_segments")
        for mutation in cases:
            with self.subTest(mutation=mutation):
                source = bytearray(macho())
                if mutation == "truncated_commands":
                    struct.pack_into("<I", source, 20, 16)
                else:
                    # __TEXT then overlaps __LINKEDIT by one byte.
                    struct.pack_into("<Q", source, 32 + 48, 257)
                self.fixture(files={"Chromium Framework": bytes(source)}, links={})
                report = payload.compare_payload(self.archive, self.framework,
                    {"sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()})
                self.assertTrue(report["archive_metadata_verified"])
                self.assertFalse(report["payload_match"])
                self.assertIsNotNone(report["reason"])

    def test_framework_inventory_limits_member_count_and_aggregate_size(self):
        self.fixture()
        with mock.patch.object(payload, "MAX_FRAMEWORK_MEMBERS", 2):
            report = payload.compare_payload(self.archive, self.framework,
                {"sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()})
        self.assertTrue(report["archive_metadata_verified"])
        self.assertFalse(report["payload_match"])
        self.assertEqual(report["reason"], "framework member count exceeds cap")

        self.fixture(files={"one": b"123456", "two": b"abcdef"}, links={})
        with mock.patch.object(payload, "MAX_FRAMEWORK_TOTAL_SIZE", 10):
            report = payload.compare_payload(self.archive, self.framework,
                {"sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()})
        self.assertTrue(report["archive_metadata_verified"])
        self.assertFalse(report["payload_match"])
        self.assertEqual(report["reason"], "framework total size exceeds cap")

    def test_invalid_pin_type_and_hex_fail_without_echoing_input(self):
        self.fixture()
        invalid_pins = ((None, "pin is malformed"),
                        ({"sha256": 123}, "pin has invalid archive SHA-256"),
                        ({"sha256": "g" * 64}, "pin has invalid archive SHA-256"),
                        ({"sha256": "f" * 63 + " "}, "pin has invalid archive SHA-256"))
        for pin, reason in invalid_pins:
            with self.subTest(pin_type=type(pin).__name__):
                report = payload.compare_payload(self.archive, self.framework, pin)
                self.assertFalse(report["archive_metadata_verified"])
                self.assertFalse(report["payload_match"])
                self.assertEqual(report["reason"], reason)
                self.assertNotIn(str(self.root), json.dumps(report))

    def test_archive_pin_mismatch_and_truncated_archive_fail(self):
        self.fixture()
        report = payload.compare_payload(self.archive, self.framework, {"sha256": "0" * 64})
        self.assertFalse(report["archive_metadata_verified"])
        data = self.archive.read_bytes()
        self.archive.write_bytes(data[:-20])
        report = payload.compare_payload(self.archive, self.framework,
            {"sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()})
        self.assertFalse(report["archive_metadata_verified"])

    def test_archive_replacement_after_hash_fails_closed(self):
        self.fixture()
        pin = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        replacement = self.replacement_archive()
        original_hash = payload._hash_file

        def hash_then_replace(stream):
            result = original_hash(stream)
            replacement.replace(self.archive)
            return result

        with mock.patch.object(payload, "_hash_file", side_effect=hash_then_replace):
            report = payload.compare_payload(self.archive, self.framework, {"sha256": pin})
        self.assertFalse(report["payload_match"])
        self.assertEqual(report["reason"], "archive changed during comparison")

    def test_archive_replacement_between_inventory_and_member_passes_fails_closed(self):
        self.fixture()
        pin = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        replacement = self.replacement_archive()
        original_inventory = payload._archive_inventory

        def inventory_then_replace(stream):
            result = original_inventory(stream)
            replacement.replace(self.archive)
            return result

        with mock.patch.object(payload, "_archive_inventory", side_effect=inventory_then_replace):
            report = payload.compare_payload(self.archive, self.framework, {"sha256": pin})
        self.assertFalse(report["payload_match"])
        self.assertEqual(report["reason"], "archive changed during comparison")

    def test_in_place_archive_mutation_after_hash_fails_closed(self):
        self.fixture()
        pin = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        original_hash = payload._hash_file

        def hash_then_mutate(stream):
            result = original_hash(stream)
            with self.archive.open("r+b") as changed:
                changed.write(b"X" * result[0])
            return result

        with mock.patch.object(payload, "_hash_file", side_effect=hash_then_mutate):
            report = payload.compare_payload(self.archive, self.framework, {"sha256": pin})
        self.assertFalse(report["payload_match"])
        self.assertEqual(report["reason"], "archive changed during comparison")

    def test_symlink_archive_leaf_fails_closed(self):
        self.fixture()
        target = self.root / "archive-target.tar.xz"
        self.archive.replace(target)
        self.archive.symlink_to(target)
        report = payload.compare_payload(self.archive, self.framework,
            {"sha256": hashlib.sha256(target.read_bytes()).hexdigest()})
        self.assertFalse(report["archive_metadata_verified"])
        self.assertFalse(report["payload_match"])
        self.assertEqual(report["reason"], "archive is not a supported regular file")
        self.assertNotIn(str(self.root), json.dumps(report))

    def test_unavailable_paths_do_not_leak_machine_paths(self):
        missing = self.root / "private-machine-path" / "missing.tar.xz"
        report = payload.compare_payload(missing, self.framework, {"sha256": "0" * 64})
        self.assertFalse(report["archive_metadata_verified"])
        self.assertNotIn(str(self.root), json.dumps(report))


if __name__ == "__main__":
    unittest.main()
