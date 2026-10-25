import hashlib
import importlib.util
import io
import json
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
    commands_end = 32 + commands_size
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
        self.fixture(files={"Chromium Framework": b"engine", path: b"pinned resources"}, links={})
        (self.framework / path).write_bytes(b"changed resources")
        report = payload.compare_payload(self.archive, self.framework,
            {"sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()})
        self.assertTrue(report["archive_metadata_verified"])
        self.assertFalse(report["payload_match"])
        self.assertEqual(next(item for item in report["members"] if item["path"] == path)["status"],
                         "mismatch")

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

    def test_unavailable_paths_do_not_leak_machine_paths(self):
        missing = self.root / "private-machine-path" / "missing.tar.xz"
        report = payload.compare_payload(missing, self.framework, {"sha256": "0" * 64})
        self.assertFalse(report["archive_metadata_verified"])
        self.assertNotIn(str(self.root), json.dumps(report))


if __name__ == "__main__":
    unittest.main()
