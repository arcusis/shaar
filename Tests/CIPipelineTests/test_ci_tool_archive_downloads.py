# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
import io
from pathlib import Path
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("install_ci_tools", ROOT / "scripts/install-ci-tools.py")
INSTALL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSTALL)


class CIToolArchiveDownloadTests(unittest.TestCase):
    def test_oversized_archive_fails_with_size_limit_error(self):
        with patch.object(INSTALL, "MAX_ARCHIVE_BYTES", 4), \
                patch.object(INSTALL.urllib.request, "urlopen", return_value=io.BytesIO(b"12345")):
            with self.assertRaisesRegex(ValueError, "exceeds the 4-byte limit"):
                INSTALL.download("https://example.invalid/large-tool", lambda seconds: None)

    def test_incomplete_http_body_retries_using_existing_backoff(self):
        class Response(io.BytesIO):
            def __init__(self, payload, remaining):
                super().__init__(payload)
                self.length = remaining

            def __enter__(self):
                return self

            def __exit__(self, *_):
                self.close()

            def read(self, size=-1):
                payload = super().read(size)
                self.length -= len(payload)
                return payload

        sleeps = []
        responses = [Response(b"partial body", 5), Response(b"complete body", 13)]
        with patch.object(INSTALL.urllib.request, "urlopen", side_effect=responses) as fetch:
            self.assertEqual(INSTALL.download("https://example.invalid/tool", sleeps.append), b"complete body")
        self.assertEqual(fetch.call_count, 2)
        self.assertEqual(sleeps, [2])
