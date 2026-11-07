# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Pin the 64MB heap snapshot cap immediately after quit cancellation."""

from pathlib import Path
import hashlib
import json
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0044-shaar-devtools-heap-snapshot-limit.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"


class HeapSnapshotLimitPatchTests(unittest.TestCase):
    def test_cap_is_64mb(self):
        source = PATCH.read_text()
        self.assertIn("kMaxHeapSnapshotBytes = 64 * 1024 * 1024", source)
        self.assertIn("kMaxHeapSnapshotBytes = 8 * 1024 * 1024", source)
        self.assertIn("64MB still rejects a runaway snapshot", source)

    def test_patch_follows_quit_cancellation(self):
        patches = json.loads(MANIFEST.read_text())["patches"]
        files = [entry["file"] for entry in patches]
        heap = str(PATCH.relative_to(ROOT))
        quit_callback = (
            "ThirdParty/ChromiumEngine/patches/0044-shaar-quit-cancellation-callback.patch"
        )
        consent = "ThirdParty/ChromiumEngine/patches/0045-shaar-website-media-consent.patch"
        self.assertEqual(files.index(heap), files.index(quit_callback) + 1)
        self.assertLess(files.index(heap), files.index(consent))
        matching = [entry for entry in patches if entry["file"] == heap]
        self.assertEqual(matching[0]["sha256"], hashlib.sha256(PATCH.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
