# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
MODULE = REPO / "scripts/verify_engine_bundle.py"
spec = importlib.util.spec_from_file_location("verify_engine_bundle", MODULE)
verifier = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(verifier)
FEED_SPEC = importlib.util.spec_from_file_location("release_feed_for_verifier_tests", REPO / "scripts/release_feed.py")
release_feed = importlib.util.module_from_spec(FEED_SPEC)
sys.modules[FEED_SPEC.name] = release_feed
FEED_SPEC.loader.exec_module(release_feed)


class EngineBundleVerifierTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.app = self.root / "Shaar.app"
        self.framework = self.app / "Contents/Frameworks/Chromium Framework.framework"
        self.versioned = self.framework / "Versions/155.0.8059.84"
        self.helpers = self.versioned / "Helpers"
        self.packaged = self.app / "Contents/Resources/ArdiaCore"
        self.archive = self.root / "engine.tar.xz"
        source = self.repo / "ThirdParty/ArdiaCore"
        (self.repo / "scripts").mkdir(parents=True)
        source.mkdir(parents=True)
        shutil.copy2(REPO / "scripts/engine_payload.py", self.repo / "scripts/engine_payload.py")
        (self.app / "Contents/MacOS").mkdir(parents=True)
        self.packaged.mkdir(parents=True)
        self.framework.mkdir(parents=True)
        (self.versioned / "Resources").mkdir(parents=True)
        (self.versioned / "Libraries").mkdir()
        self.helpers.mkdir()
        self.payload = b"engine payload fixture"
        self.engine_plist = plistlib.dumps({"CFBundleIdentifier": verifier.FRAMEWORK_ID})
        (self.versioned / "Resources/data.bin").write_bytes(self.payload)
        (self.versioned / "Resources/Info.plist").write_bytes(self.engine_plist)
        (self.versioned / "Chromium Framework").write_bytes(b"framework binary")
        for name, target in {
            "Chromium Framework": "Versions/Current/Chromium Framework",
            "Helpers": "Versions/Current/Helpers",
            "Libraries": "Versions/Current/Libraries",
            "Resources": "Versions/Current/Resources",
        }.items():
            (self.framework / name).symlink_to(target)
        (self.framework / "Versions/Current").symlink_to("155.0.8059.84")
        contents = self.app / "Contents"
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": verifier.APP_ID, "CFBundleExecutable": verifier.APP_EXECUTABLE,
        }))
        (contents / "MacOS/ArcusisBrowser").write_bytes(b"fixture executable")
        self.helper_map = {}
        for name, (identifier, executable) in verifier.HELPERS.items():
            helper = self.helpers / name
            (helper / "Contents/MacOS").mkdir(parents=True)
            (helper / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": identifier, "CFBundleExecutable": executable,
            }))
            (helper / "Contents/MacOS" / executable).write_bytes(b"helper fixture")
            self.helper_map[name] = identifier
        pin = {
            "repository": "https://example.invalid/engine", "sourceCommit": "1" * 40,
            "sourceTag": "v1.2.3", "engineTree": "2" * 40,
            "archiveURL": "https://example.invalid/engine.tar.xz", "sha256": "0" * 64,
            "chromiumVersion": "155.0.8059.84", "architecture": "arm64",
        }
        self.pin_path = source / "pin.json"
        (source / "LICENSE").write_text("fixture license\n")
        (source / "NOTICE").write_text("fixture notice\n")
        self._write_archive(pin)
        self.pin_path.write_text(json.dumps(pin, sort_keys=True) + "\n")
        for filename in ("pin.json", "LICENSE", "NOTICE"):
            (self.packaged / filename).write_bytes((source / filename).read_bytes())

    def tearDown(self):
        self.temp.cleanup()

    def _write_archive(self, pin):
        with tarfile.open(self.archive, "w:xz") as tar:
            root_name = "Chromium Framework.framework"
            root_info = tarfile.TarInfo(root_name)
            root_info.type = tarfile.DIRTYPE
            tar.addfile(root_info)
            versions_info = tarfile.TarInfo(root_name + "/Versions")
            versions_info.type = tarfile.DIRTYPE
            tar.addfile(versions_info)
            current = tarfile.TarInfo(root_name + "/Versions/Current")
            current.type = tarfile.SYMTYPE
            current.linkname = "155.0.8059.84"
            tar.addfile(current)
            for name in ("Chromium Framework", "Helpers", "Libraries", "Resources"):
                link = self.framework / name
                tar.add(link, arcname=root_name + "/" + name, recursive=False)
            tar.add(self.versioned, arcname=root_name + "/Versions/155.0.8059.84")
        pin["sha256"] = hashlib.sha256(self.archive.read_bytes()).hexdigest()

    def _codesign_result(self, argv):
        if "--verify" in argv:
            self.assertEqual(argv[:5], ["/usr/bin/codesign", "--verify", "--strict", "--deep", "--verbose=2"])
            return 0, b""
        path = Path(argv[-1])
        if path == self.app:
            identifier = verifier.APP_ID
        elif path == self.framework:
            identifier = verifier.FRAMEWORK_ID
        else:
            identifier = self.helper_map[path.name]
        digest = hashlib.sha1(path.name.encode()).hexdigest()
        output = (f"Identifier={identifier}\nSignature=adhoc\nTeamIdentifier=not set\nCDHash={digest}\n").encode()
        return 0, output

    def verify(self):
        with patch.object(verifier, "_bounded_run", side_effect=self._codesign_result):
            return verifier.verify(self.repo, self.app, self.archive)

    def reset(self):
        self.temp.cleanup()
        self.setUp()

    def test_real_parser_payload_and_report_are_deterministic_and_bounded(self):
        first = self.verify()
        second = self.verify()
        self.assertEqual(first, second)
        self.assertEqual(first["verification"], "passed", first)
        self.assertTrue(first["bundleIdentityVerified"])
        self.assertTrue(first["payloadMatch"])
        self.assertEqual(first["signatureKind"], "adhoc")
        self.assertEqual(len(first["signatureIdentitiesSha256"]), 10)
        self.assertFalse(first["sourceProvenanceVerified"])
        self.assertFalse(first["notarizationVerified"])
        self.assertFalse(first["releaseReady"])
        self.assertGreater(first["payload"]["memberCount"], 12)
        self.assertEqual(first["payload"]["mismatchCount"], 0)
        encoded = json.dumps(first, sort_keys=True, separators=(",", ":"))
        self.assertNotIn(str(self.root), encoded)
        self.assertNotIn("timestamp", encoded.lower())
        self.assertNotIn("members", encoded)

    def test_malformed_pin_packaged_substitution_and_helper_mismatch_fail(self):
        self.pin_path.write_text("{bad\n")
        self.assertEqual(self.verify()["reason"], "pin_malformed")
        self.reset()
        (self.packaged / "LICENSE").write_text("substituted")
        self.assertEqual(self.verify()["reason"], "packaged_license_mismatch")
        self.reset()
        (self.helpers / "Chromium Helper.app/Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.attacker.helper", "CFBundleExecutable": "Chromium Helper",
        }))
        self.assertEqual(self.verify()["reason"], "helper_identity_mismatch")

    def test_verifier_checks_the_shipping_identifier_and_rejects_the_harness_identifier(self):
        config = release_feed.load_config(REPO / "scripts/release-config.sh")
        self.assertEqual(verifier.APP_ID, config.bundle_identifier)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": config.verification_bundle_identifier,
            "CFBundleExecutable": verifier.APP_EXECUTABLE,
        }))
        self.assertEqual(self.verify()["reason"], "bundle_identity_mismatch")

    def test_missing_helper_and_escaping_framework_link_fail(self):
        shutil.rmtree(self.helpers / "Chromium Helper.app")
        self.assertEqual(self.verify()["reason"], "helper_set_mismatch")
        self.reset()
        (self.framework / "Resources").unlink()
        (self.framework / "Resources").symlink_to("../../../../outside")
        self.assertEqual(self.verify()["reason"], "framework_structure_invalid")

    def test_archive_and_payload_substitution_fail(self):
        with self.archive.open("ab") as stream:
            stream.write(b"substitution")
        self.assertEqual(self.verify()["reason"], "archive_pin_mismatch")
        self.reset()
        (self.versioned / "Resources/data.bin").write_bytes(b"different payload")
        self.assertEqual(self.verify()["reason"], "payload_mismatch")

    def test_codesign_failure_malformed_output_and_identity_mismatch_fail(self):
        with patch.object(verifier, "_bounded_run", return_value=(1, b"private diagnostic")):
            result = verifier.verify(self.repo, self.app, self.archive)
        self.assertEqual(result["reason"], "codesign_verification_failed")
        self.assertNotIn("private diagnostic", json.dumps(result))
        with patch.object(verifier, "_bounded_run", side_effect=lambda argv: (0,
            b"Identifier=com.unknown\nSignature=adhoc\nTeamIdentifier=not set\nCDHash=" + b"a" * 40)):
            self.assertEqual(verifier.verify(self.repo, self.app, self.archive)["reason"], "signature_identifier_mismatch")
        with patch.object(verifier, "_bounded_run", side_effect=lambda argv: (0,
            b"Identifier=com.arcusis.browser\nTeamIdentifier=?\n")):
            self.assertEqual(verifier.verify(self.repo, self.app, self.archive)["reason"], "signature_data_unrecognized")

    def test_developer_id_chain_must_be_exact_and_match_team(self):
        valid = (b"Identifier=com.arcusis.browser\nTeamIdentifier=ABCDE12345\n"
                 b"Authority=Developer ID Application: Example Corp (ABCDE12345)\n"
                 b"Authority=Developer ID Certification Authority\nAuthority=Apple Root CA\nCDHash=" + b"b" * 40)
        def result(argv):
            if "--verify" in argv:
                return 0, b""
            path = Path(argv[-1])
            expected = (verifier.APP_ID if path == self.app else
                        verifier.FRAMEWORK_ID if path == self.framework else self.helper_map[path.name])
            return 0, valid.replace(b"Identifier=com.arcusis.browser", f"Identifier={expected}".encode())
        with patch.object(verifier, "_bounded_run", side_effect=result):
            passed = verifier.verify(self.repo, self.app, self.archive)
        self.assertEqual(passed["verification"], "passed", passed)
        self.assertEqual(passed["signatureKind"], "developer_id")
        invalid = valid.replace(b"Authority=Apple Root CA", b"Authority=")
        with patch.object(verifier, "_bounded_run", side_effect=lambda argv:
                          (0, b"" if "--verify" in argv else invalid)):
            self.assertEqual(verifier.verify(self.repo, self.app, self.archive)["reason"], "signature_data_unrecognized")

    def test_report_is_private_atomic_and_replaces_stale_pass(self):
        report = self.root / "report.json"
        report.write_text('{"verification":"passed"}\n')
        os.chmod(report, 0o644)
        result = self.verify()
        verifier._atomic_report(report, result, [self.repo, self.archive, self.app])
        self.assertEqual(report.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads(report.read_text()), result)
        (self.packaged / "pin.json").write_text("substituted")
        failed = self.verify()
        verifier._atomic_report(report, failed, [self.repo, self.archive, self.app])
        self.assertEqual(json.loads(report.read_text())["verification"], "failed")
        link = self.root / "link.json"
        link.symlink_to(report)
        with self.assertRaises(verifier.VerifyError):
            verifier._atomic_report(link, failed, [self.repo, self.archive, self.app])
        with self.assertRaises(verifier.VerifyError):
            verifier._atomic_report(self.archive, failed, [self.repo, self.archive, self.app])


if __name__ == "__main__":
    unittest.main()
