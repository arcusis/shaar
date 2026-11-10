# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "fetch-framework-devtools.py"
BUNDLE = REPO / "scripts" / "bundle-app.sh"


def load_fetcher():
    spec = importlib.util.spec_from_file_location("fetch_framework_devtools", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FetchFrameworkDevToolsTests(unittest.TestCase):
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
