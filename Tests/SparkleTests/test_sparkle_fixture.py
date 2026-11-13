# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import base64
import io
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request
import zipfile

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import sparkle_fixture as fixture


class SparkleFixtureTests(unittest.TestCase):
    def test_previous_release_download_retries_transient_gateway_failure(self):
        gateway_error = urllib.error.HTTPError("https://example.test/previous.zip", 504, "Gateway Time-out", {}, None)
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(fixture.urllib.request, "urlopen", side_effect=[gateway_error, io.BytesIO(b"complete")]) as open_url, \
                patch.object(fixture.time, "sleep") as sleep:
            previous = Path(temporary) / "previous.zip"
            fixture.download_previous_release("https://example.test/previous.zip", previous)
            self.assertEqual(previous.read_bytes(), b"complete")
            self.assertEqual(open_url.call_count, 2)
            sleep.assert_called_once_with(1)

    def test_previous_release_download_retries_request_timeout(self):
        timeout_error = urllib.error.HTTPError("https://example.test/previous.zip", 408, "Request Timeout", {}, None)
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(fixture.urllib.request, "urlopen", side_effect=[timeout_error, io.BytesIO(b"complete")]) as open_url, \
                patch.object(fixture.time, "sleep") as sleep:
            previous = Path(temporary) / "previous.zip"
            fixture.download_previous_release("https://example.test/previous.zip", previous)
            self.assertEqual(previous.read_bytes(), b"complete")
            self.assertEqual(open_url.call_count, 2)
            sleep.assert_called_once_with(1)

    def test_previous_release_download_fails_fast_on_404(self):
        missing = urllib.error.HTTPError("https://example.test/previous.zip", 404, "Not Found", {}, None)
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(fixture.urllib.request, "urlopen", side_effect=missing) as open_url, \
                patch.object(fixture.time, "sleep") as sleep:
            with self.assertRaises(urllib.error.HTTPError):
                fixture.download_previous_release("https://example.test/previous.zip", Path(temporary) / "previous.zip")
            open_url.assert_called_once()
            sleep.assert_not_called()

    def test_previous_release_download_stops_after_three_gateway_failures(self):
        gateway_error = urllib.error.HTTPError("https://example.test/previous.zip", 504, "Gateway Time-out", {}, None)
        with tempfile.TemporaryDirectory() as temporary, \
                patch.object(fixture.urllib.request, "urlopen", side_effect=gateway_error) as open_url, \
                patch.object(fixture.time, "sleep") as sleep:
            previous = Path(temporary) / "previous.zip"
            with self.assertRaises(urllib.error.HTTPError):
                fixture.download_previous_release("https://example.test/previous.zip", previous)
            self.assertFalse(previous.exists())
            self.assertEqual(open_url.call_count, 3)
            self.assertEqual([call.args[0] for call in sleep.call_args_list], [1, 2])

    def test_diagnostic_patch_fails_closed_on_sdk_callback_drift(self):
        source = """- (void)showUpdaterError:(NSError *)__unused error acknowledgement:(void (^)(void))acknowledgement
{
    acknowledgement();
}"""
        result = fixture.add_error_diagnostics(source)
        self.assertEqual(result.count("acknowledgement();"), 1)
        self.assertIn("cursor.userInfo[NSUnderlyingErrorKey]", result)
        for changed in ("different callback", source + source):
            with self.assertRaisesRegex(ValueError, "requires review"):
                fixture.add_error_diagnostics(changed)

    def test_native_entrypoint_refuses_local_execution_before_reading_payload(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(fixture, "verify_archive") as verify:
            with self.assertRaisesRegex(RuntimeError, "hosted macOS"):
                fixture.run_simulation(Path("missing"))
            verify.assert_not_called()

    def test_install_proof_rejects_noop_download_and_data_loss(self):
        valid = dict(case="valid", status=0, log="Installation Finished.",
                     requests=["/appcast.xml", "/update.zip"], before="old", after="new", expected="new",
                     data_before="data", data_after="data", executable_changed=True, version="2")
        fixture.assert_install(**valid)
        for change in (dict(status=4), dict(log="Downloaded"), dict(requests=["/appcast.xml"]),
                       dict(after="old"), dict(data_after="lost"), dict(executable_changed=False), dict(version="1")):
            with self.subTest(change=change), self.assertRaises(AssertionError):
                fixture.assert_install(**(valid | change))

    def test_negative_proof_requires_signature_error_and_unchanged_bundle(self):
        negative = dict(case="wrong-signature", status=1,
                        log="Error: Update has failed due to error 3001 (SUSparkleErrorDomain). EdDSA signature validation failed.",
                        requests=["/appcast.xml", "/update.zip"], before="old", after="old", expected="new",
                        data_before="data", data_after="data", executable_changed=False, version="1")
        fixture.assert_install(**negative)
        fixture.assert_install(**(negative | dict(
            log="Error: Update has failed due to error 4005 (SUSparkleErrorDomain). (Ed)DSA signature validation before unarchiving failed.")))
        for change in (dict(status=0), dict(status=4), dict(log="Network failed"), dict(after="new"),
                       dict(log="Error: Update has failed due to error 4005 (SUSparkleErrorDomain). File copy failed."),
                       dict(log=negative["log"] + " Installation Finished."), dict(data_after="lost")):
            with self.subTest(change=change), self.assertRaises(AssertionError):
                fixture.assert_install(**(negative | change))

    def test_archive_digest_and_paths_are_verified(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "candidate.zip"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("Shaar.app/Contents/Info.plist", "fixture")
            fixture.verify_archive(path, fixture.sha256(path), path.stat().st_size)
            with self.assertRaisesRegex(ValueError, "SHA256"):
                fixture.verify_archive(path, "0" * 64)
            with self.assertRaisesRegex(ValueError, "size"):
                fixture.verify_archive(path, fixture.sha256(path), 1)
            with zipfile.ZipFile(path, "a") as archive:
                archive.writestr("../escape", "fixture")
            with self.assertRaisesRegex(ValueError, "unsafe"):
                fixture.verify_archive(path, fixture.sha256(path))

    def test_fingerprint_covers_payload_and_symlink_targets(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "binary").write_bytes(b"old")
            (root / "link").symlink_to("binary")
            before = fixture.fingerprint(root)
            (root / "binary").write_bytes(b"new")
            self.assertNotEqual(before, fixture.fingerprint(root))
            (root / "link").unlink()
            (root / "link").symlink_to("/tmp")
            with self.assertRaisesRegex(ValueError, "escapes"):
                fixture.fingerprint(root)

    def test_archive_symlinks_cannot_escape_before_extraction(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "candidate.zip"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("Shaar.app/Contents/Info.plist", "fixture")
                link = zipfile.ZipInfo("Shaar.app/Contents/escape")
                link.create_system = 3
                link.external_attr = 0o120777 << 16
                archive.writestr(link, "../../../outside")
            with self.assertRaisesRegex(ValueError, "escaping symlink"):
                fixture.verify_archive(path, fixture.sha256(path))

    def test_ephemeral_key_uses_private_file_and_matching_public_key(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "fixture.key"
            public = fixture.write_key(path)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            key = Ed25519PrivateKey.from_private_bytes(base64.b64decode(path.read_bytes()))
            self.assertEqual(base64.b64decode(public), key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw))
            with self.assertRaises(FileExistsError):
                fixture.write_key(path)

    def test_server_only_serves_fixture_routes_and_records_download(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "update.zip"
            archive.write_bytes(b"fixture archive")
            with fixture.feed_server(archive, "fixture-signature") as (url, requests):
                with urllib.request.urlopen(url) as response:
                    feed = response.read()
                self.assertIn(b"127.0.0.1:", feed)
                self.assertNotIn(b"description", feed)
                with urllib.request.urlopen(url.replace("appcast.xml", "update.zip")) as response:
                    self.assertEqual(response.read(), archive.read_bytes())
                with self.assertRaises(urllib.error.HTTPError):
                    urllib.request.urlopen(url.replace("appcast.xml", "fixture.key"))
                self.assertEqual(requests, ["/appcast.xml", "/update.zip"])

    def test_helper_cleanup_uses_exact_printed_owned_pids(self):
        listing = "123 /tmp/owned/Driver.app/Contents/MacOS/sparkle-cli\n124 /tmp/owned/Driver.app/helper\n125 /tmp/owned-other/helper\n126 /Applications/Shaar.app/Contents/MacOS/Shaar\n"
        with patch.object(fixture.subprocess, "check_output", return_value=listing), \
                patch.object(fixture.os, "kill") as kill, patch("builtins.print") as output:
            self.assertEqual(fixture.stop_helpers(Path("/tmp/owned"), 123), [124])
            output.assert_called_once_with("Stopping owned Sparkle helper PID: 124", flush=True)
            kill.assert_called_once_with(124, fixture.signal.SIGKILL)


if __name__ == "__main__":
    unittest.main()
