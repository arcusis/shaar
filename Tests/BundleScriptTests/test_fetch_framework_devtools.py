# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
import io
import tempfile
import unittest
from unittest import mock
from pathlib import Path
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "fetch-framework-devtools.py"
BUNDLE = REPO / "scripts" / "bundle-app.sh"


def load_fetcher():
    spec = importlib.util.spec_from_file_location("fetch_framework_devtools", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FetchFrameworkDevToolsTests(unittest.TestCase):
    def test_output_path_rejects_roots_symlinks_and_non_directories(self):
        fetcher = load_fetcher()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            valid = root / "FrameworkDevTools"
            self.assertEqual(fetcher.validate_output_path(valid), valid.resolve())
            file_path = root / "file"
            file_path.write_text("not a directory")
            link = root / "link"
            link.symlink_to(root, target_is_directory=True)
            invalid = (Path("/"), fetcher.ROOT, fetcher.ROOT.parent,
                       Path(tempfile.gettempdir()), file_path, link)
            for path in invalid:
                with self.subTest(path=path), self.assertRaises(ValueError):
                    fetcher.validate_output_path(path)

    def test_output_path_rejects_symlinked_ancestors(self):
        fetcher = load_fetcher()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            redirect = root / "redirect"
            redirect.symlink_to(REPO.parent, target_is_directory=True)
            escaped = redirect / "generated" / "FrameworkDevTools"

            with self.assertRaisesRegex(ValueError, "symlink"):
                fetcher.validate_output_path(escaped)

    def test_release_url_names_the_pinned_github_asset(self):
        fetcher = load_fetcher()

        self.assertEqual(fetcher.release_asset_name("react"), "react-8.0.0.crx")
        self.assertEqual(fetcher.release_asset_name("vue"), "vue-7.7.7.crx")
        self.assertEqual(fetcher.release_asset_name("angular"), "angular-1.22.1.crx")
        self.assertEqual(
            fetcher.release_asset_url("react"),
            "https://github.com/arcusis/shaar/releases/download/"
            "framework-devtools-pins/react-8.0.0.crx",
        )

    def test_transient_release_download_failure_is_retried(self):
        fetcher = load_fetcher()
        error = fetcher.urllib.error.HTTPError("https://example.invalid/react.crx", 503, "busy", {}, None)
        sleeps = []
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "react.crx"
            with patch.object(fetcher.urllib.request, "urlopen",
                              side_effect=[error, io.BytesIO(b"pinned bytes")]) as open_url:
                fetcher.download_url("https://example.invalid/react.crx", "react", destination, sleeps.append)
            self.assertEqual(destination.read_bytes(), b"pinned bytes")

        self.assertEqual(open_url.call_count, 2)
        self.assertEqual(sleeps, [2])

    def test_bundle_does_not_refresh_archives_from_the_web_store(self):
        text = BUNDLE.read_text()
        start = text.index("scripts/fetch-framework-devtools.py")
        invocation = text[start:text.index("mkdir -p", start)]

        self.assertNotIn("--download", invocation)
        self.assertNotIn("clients2.google.com", invocation)

    def test_mismatched_download_leaves_the_pinned_cache_unchanged(self):
        fetcher = load_fetcher()

        def write_wrong(name, destination):
            destination.write_bytes(b"not the pinned archive")

        with tempfile.TemporaryDirectory() as directory:
            archive_dir = Path(directory)
            pinned = archive_dir / "react.crx"
            pinned.write_bytes(b"pinned bytes")
            with self.assertRaises(ValueError) as caught:
                fetcher.install_pinned("react", archive_dir, write_wrong, "test source")
            message = str(caught.exception)
            self.assertIn("does not match pin", message)
            self.assertIn(fetcher.PINS["react"].sha256, message)
            self.assertEqual(pinned.read_bytes(), b"pinned bytes")
            candidate = archive_dir / "react.crx.candidate"
            self.assertEqual(candidate.read_bytes(), b"not the pinned archive")

    def test_oversized_cache_entry_is_rejected_before_full_file_read(self):
        fetcher = load_fetcher()
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory) / "react.crx"
            with archive.open("wb") as handle:
                handle.truncate(fetcher.MAX_ARCHIVE_SIZE + 1)

            with mock.patch.object(Path, "read_bytes", side_effect=AssertionError("unbounded read")):
                self.assertFalse(fetcher.archive_matches("react", archive))

    def test_oversized_archive_is_rejected_before_unpack_reads_it(self):
        fetcher = load_fetcher()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / "react.crx"
            with archive.open("wb") as handle:
                handle.truncate(fetcher.MAX_ARCHIVE_SIZE + 1)

            with mock.patch.object(Path, "read_bytes", side_effect=AssertionError("unbounded read")):
                with self.assertRaisesRegex(ValueError, "size limit"):
                    fetcher.unpack("react", archive, root / "output")
