# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import base64
import http.server
import importlib.util
import plistlib
import sys
import tempfile
import threading
import unittest
import zipfile
from dataclasses import replace
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("release_feed", REPO / "scripts" / "release_feed.py")
release_feed = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = release_feed
SPEC.loader.exec_module(release_feed)

PRIVATE_KEY = Ed25519PrivateKey.generate()
KEY = base64.b64encode(
    PRIVATE_KEY.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
).decode()
CONFIG_TEXT = f"""# comment
SHAAR_BUNDLE_IDENTIFIER=com.arcusis.browser
SHAAR_BUNDLE_VERSION=1.2.3
SHAAR_BUILD_VERSION=7
SHAAR_MINIMUM_SYSTEM_VERSION=26.0
SHAAR_RELEASE_REPOSITORY=arcusis/shaar
SHAAR_FEED_URL=https://arcusis.github.io/shaar/appcast.xml
SHAAR_SPARKLE_PUBLIC_ED_KEY={KEY}
SHAAR_SPARKLE_KEY_ACCOUNT=shaar
"""
NOTES = "                    <li>Automatic updates.</li>"
PUB_DATE = "Sat, 31 Oct 2026 10:00:00 GMT"


class ReleaseFeedTests(unittest.TestCase):
    def setUp(self):
        self.config = release_feed.parse_config(CONFIG_TEXT)
        self.temp = tempfile.TemporaryDirectory(prefix="release-feed-tests-")
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def _appcast(self, config=None, *, length=123, signature="c2lnbmF0dXJl"):
        return release_feed.render_appcast(
            config or self.config, length=length, signature=signature, notes_html=NOTES, pub_date=PUB_DATE
        )

    def _zip(self, info=None, *, prefix="Shaar.app"):
        plist = {
            "CFBundleIdentifier": "com.arcusis.browser",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "7",
            "SUFeedURL": "https://arcusis.github.io/shaar/appcast.xml",
            "SUPublicEDKey": KEY,
        } | (info or {})
        path = self.root / "Shaar-1.2.3-macos.zip"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr(f"{prefix}/Contents/Info.plist", plistlib.dumps(plist))
            archive.writestr(f"{prefix}/Contents/MacOS/ArcusisBrowser", b"binary")
        return path

    def test_checked_in_config_parses_with_placeholder_key(self):
        config = release_feed.load_config()

        self.assertEqual(config.bundle_identifier, "com.arcusis.browser")
        self.assertEqual(config.repository, "arcusis/shaar")
        self.assertEqual(config.feed_url, "https://arcusis.github.io/shaar/appcast.xml")
        self.assertFalse(config.public_key_is_ready)

    def test_names_follow_tag_and_asset_contract(self):
        self.assertEqual(self.config.tag, "v1.2.3")
        self.assertEqual(self.config.appcast_name, "appcast.xml")
        self.assertEqual(self.config.dmg_name, "Shaar_1.2.3_aarch64.dmg")
        self.assertEqual(self.config.zip_name, "Shaar-1.2.3-macos.zip")
        self.assertEqual(
            self.config.zip_url,
            "https://github.com/arcusis/shaar/releases/download/v1.2.3/Shaar-1.2.3-macos.zip",
        )

    def test_config_rejects_bad_versions_repository_feed_and_shell_syntax(self):
        cases = {
            "SHAAR_BUNDLE_VERSION=1.2.3": "SHAAR_BUNDLE_VERSION=1.2",
            "SHAAR_BUILD_VERSION=7": "SHAAR_BUILD_VERSION=07",
            "SHAAR_RELEASE_REPOSITORY=arcusis/shaar": "SHAAR_RELEASE_REPOSITORY=shaar",
            "SHAAR_FEED_URL=https://": "SHAAR_FEED_URL=http://",
            "SHAAR_BUNDLE_IDENTIFIER=com.arcusis.browser": "SHAAR_BUNDLE_IDENTIFIER=$(id)",
            "SHAAR_BUNDLE_VERSION=1.2.3\n": "SHAAR_BUNDLE_VERSION=1.2.3;id\n",
            "SHAAR_RELEASE_REPOSITORY=arcusis/shaar\n": "SHAAR_RELEASE_REPOSITORY=arcusis/shaar|id\n",
            "SHAAR_MINIMUM_SYSTEM_VERSION=26.0": "SHAAR_MINIMUM_SYSTEM_VERSION=26",
        }
        for old, new in cases.items():
            self.assertIn(old, CONFIG_TEXT)
            with self.subTest(new=new), self.assertRaises(release_feed.ReleaseError):
                release_feed.parse_config(CONFIG_TEXT.replace(old, new))
        for identifier in ("browser", "com..arcusis"):
            with self.subTest(identifier=identifier), self.assertRaisesRegex(release_feed.ReleaseError, "reverse-DNS"):
                release_feed.parse_config(
                    CONFIG_TEXT.replace("SHAAR_BUNDLE_IDENTIFIER=com.arcusis.browser", f"SHAAR_BUNDLE_IDENTIFIER={identifier}")
                )
        with self.assertRaisesRegex(release_feed.ReleaseError, "missing SHAAR_FEED_URL"):
            release_feed.parse_config(
                "\n".join(line for line in CONFIG_TEXT.splitlines() if "FEED_URL" not in line)
            )

    def test_public_key_must_be_32_byte_base64(self):
        self.assertTrue(self.config.public_key_is_ready)
        for key in ("SHAAR_SPARKLE_PUBLIC_ED_KEY_PLACEHOLDER", base64.b64encode(bytes(31)).decode(), "not base64!"):
            with self.subTest(key=key):
                self.assertFalse(replace(self.config, public_ed_key=key).public_key_is_ready)

    def test_rendered_appcast_round_trips_through_validation(self):
        item = release_feed.validate_appcast(self._appcast(), self.config)

        self.assertEqual(item.title, "1.2.3")
        self.assertEqual(item.build_version, 7)
        self.assertEqual(item.minimum_system_version, "26.0")
        self.assertEqual(item.length, 123)
        self.assertEqual(item.signature, "c2lnbmF0dXJl")
        self.assertEqual(item.url, self.config.zip_url)

    def test_validation_requires_signature_unless_dry_run(self):
        unsigned = self._appcast(signature=None)

        with self.assertRaisesRegex(release_feed.ReleaseError, "EdDSA"):
            release_feed.validate_appcast(unsigned, self.config)
        self.assertIsNone(release_feed.validate_appcast(unsigned, self.config, require_signature=False).signature)

    def test_validation_rejects_appcast_for_another_release(self):
        cases = (
            replace(self.config, bundle_version="1.2.4"),
            replace(self.config, build_version=8),
            replace(self.config, minimum_system_version="15.0"),
            replace(self.config, repository="arcusis/other"),
        )
        for other in cases:
            with self.subTest(other=other), self.assertRaises(release_feed.ReleaseError):
                release_feed.validate_appcast(self._appcast(other), self.config)

    def test_validation_rejects_malformed_or_multi_item_feeds(self):
        appcast = self._appcast()
        start = appcast.index("<item>")
        end = appcast.index("</item>") + len("</item>")
        two_items = appcast[:end] + appcast[start:end] + appcast[end:]
        for text in ("<rss", two_items, appcast.replace('length="123"', 'length="0"')):
            with self.subTest(text=text[:40]), self.assertRaises(release_feed.ReleaseError):
                release_feed.validate_appcast(text, self.config)

    def test_notes_cannot_escape_cdata_or_be_empty(self):
        for notes in ("<li>]]></li>", "   "):
            with self.subTest(notes=notes), self.assertRaises(release_feed.ReleaseError):
                release_feed.render_appcast(self.config, length=1, signature=None, notes_html=notes, pub_date=PUB_DATE)

    def test_update_zip_must_match_identity_feed_and_length(self):
        archive = self._zip()
        length = archive.stat().st_size

        release_feed.validate_update_zip(archive, self.config, expected_length=length)
        with self.assertRaisesRegex(release_feed.ReleaseError, "bytes"):
            release_feed.validate_update_zip(archive, self.config, expected_length=length + 1)
        for key, value in (
            ("CFBundleIdentifier", "com.arcusis.other"),
            ("CFBundleVersion", "6"),
            ("SUFeedURL", "https://example.com/appcast.xml"),
            ("SUPublicEDKey", "SHAAR_SPARKLE_PUBLIC_ED_KEY_PLACEHOLDER"),
        ):
            with self.subTest(key=key):
                archive = self._zip({key: value})
                with self.assertRaisesRegex(release_feed.ReleaseError, key):
                    release_feed.validate_update_zip(archive, self.config, expected_length=archive.stat().st_size)

    def test_update_zip_requires_top_level_app(self):
        archive = self._zip(prefix="nested/Shaar.app")

        with self.assertRaisesRegex(release_feed.ReleaseError, "top-level"):
            release_feed.validate_update_zip(archive, self.config, expected_length=archive.stat().st_size)

    def test_release_build_must_exceed_published_build(self):
        published = self._appcast(replace(self.config, build_version=6))

        self.assertEqual(release_feed.ensure_newer_than_published(self.config, published), 6)
        for build in (7, 8):
            with self.subTest(build=build), self.assertRaisesRegex(release_feed.ReleaseError, "not newer"):
                release_feed.ensure_newer_than_published(
                    self.config, self._appcast(replace(self.config, build_version=build))
                )

    def test_update_signature_must_verify_over_zip_bytes_with_public_key(self):
        archive = self._zip()
        signature = base64.b64encode(PRIVATE_KEY.sign(archive.read_bytes())).decode()
        other_key = base64.b64encode(
            Ed25519PrivateKey.generate().public_key().public_bytes(
                serialization.Encoding.Raw, serialization.PublicFormat.Raw
            )
        ).decode()

        release_feed.verify_update_signature(archive, signature, KEY)
        for bad_signature, key in (
            (signature, other_key),
            (base64.b64encode(bytes(64)).decode(), KEY),
            ("not base64!", KEY),
            (signature, "SHAAR_SPARKLE_PUBLIC_ED_KEY_PLACEHOLDER"),
        ):
            with self.subTest(key=key[:8], signature=bad_signature[:8]), self.assertRaises(release_feed.ReleaseError):
                release_feed.verify_update_signature(archive, bad_signature, key)
        archive.write_bytes(archive.read_bytes() + b"tampered")
        with self.assertRaisesRegex(release_feed.ReleaseError, "EdDSA"):
            release_feed.verify_update_signature(archive, signature, KEY)

    def _serve(self, status, body=b""):
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(status)
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_port}/appcast.xml"

    def _check_newer(self, url):
        config_path = self.root / "release-config.sh"
        config_path.write_text(CONFIG_TEXT)
        return release_feed.main(["--config", str(config_path), "check-newer", "--feed-url", url])

    def test_live_feed_check_treats_only_404_as_first_release(self):
        self.assertEqual(self._check_newer(self._serve(404)), 0)
        older = self._appcast(replace(self.config, build_version=6)).encode()
        self.assertEqual(self._check_newer(self._serve(200, older)), 0)
        for status, body in ((200, self._appcast().encode()), (500, b""), (403, b""), (200, b"<html>")):
            with self.subTest(status=status, body=body[:10]):
                self.assertEqual(self._check_newer(self._serve(status, body)), 1)
        self.assertEqual(self._check_newer("http://127.0.0.1:9/appcast.xml"), 1)

    def test_cli_rejects_appcast_whose_signature_does_not_match_zip(self):
        config_path = self.root / "release-config.sh"
        config_path.write_text(CONFIG_TEXT)
        archive = self._zip()
        appcast = self.root / "appcast.xml"
        forged = base64.b64encode(Ed25519PrivateKey.generate().sign(archive.read_bytes())).decode()
        appcast.write_text(self._appcast(length=archive.stat().st_size, signature=forged))

        self.assertEqual(
            release_feed.main(["--config", str(config_path), "validate", "--appcast", str(appcast), "--zip", str(archive)]),
            1,
        )

    def test_cli_writes_then_validates_appcast(self):
        config_path = self.root / "release-config.sh"
        config_path.write_text(CONFIG_TEXT)
        notes = self.root / "notes.html"
        notes.write_text(NOTES)
        archive = self._zip()
        appcast = self.root / "appcast.xml"

        self.assertEqual(
            release_feed.main([
                "--config", str(config_path), "write", "--zip", str(archive), "--notes", str(notes),
                "--signature", base64.b64encode(PRIVATE_KEY.sign(archive.read_bytes())).decode(),
                "--output", str(appcast),
            ]),
            0,
        )
        self.assertEqual(
            release_feed.main(["--config", str(config_path), "validate", "--appcast", str(appcast), "--zip", str(archive)]),
            0,
        )
        self.assertEqual(release_feed.main(["--config", str(config_path), "check-key"]), 0)


if __name__ == "__main__":
    unittest.main()
