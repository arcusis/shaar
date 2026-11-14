# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import hashlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("install_ci_tools", ROOT / "scripts/install-ci-tools.py")
INSTALL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(INSTALL)


class CIToolCacheParentSymlinkTests(unittest.TestCase):
    def test_installer_rejects_symlinked_cache_parent_before_download(self):
        payload = b"pinned archive"
        digest = hashlib.sha256(payload).hexdigest()
        pin = {"url": "https://example.invalid/tool", "sha256": digest}

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            outside = root / "outside"
            outside.mkdir()
            sentinel = outside / "keep.txt"
            sentinel.write_text("preserve this cache")
            linked_parent = root / "linked-parent"
            linked_parent.symlink_to(outside, target_is_directory=True)
            cache = linked_parent / "cache"

            with patch.object(INSTALL.urllib.request, "urlopen", return_value=io.BytesIO(payload)) as fetch:
                with self.assertRaisesRegex(ValueError, "symlinked parent"):
                    INSTALL.archive_payload(pin, cache)
                fetch.assert_not_called()

            self.assertEqual(sentinel.read_text(), "preserve this cache")
            self.assertFalse((outside / "cache").exists())


if __name__ == "__main__":
    unittest.main()
