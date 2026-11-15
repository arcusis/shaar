# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Pin the developer-only heap profiler commands and their snapshot assembly."""

from pathlib import Path
import hashlib
import json
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0041-shaar-devtools-heap-profiler.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"


class HeapProfilerPatchTests(unittest.TestCase):
    def test_heap_commands_are_developer_only_and_assemble_chunks(self):
        source = PATCH.read_text()
        self.assertIn("HeapProfiler.takeHeapSnapshot", source)
        self.assertIn("HeapProfiler.startTrackingHeapObjects", source)
        self.assertIn("HeapProfiler.stopTrackingHeapObjects", source)
        self.assertIn("HeapProfiler.addHeapSnapshotChunk", source)
        self.assertIn("id <= SHAAR_DEVTOOLS_HEAP_PROFILER_STOP_TRACKING_HEAP_OBJECTS", source)
        self.assertIn('"command":80', source)
        self.assertIn("heap snapshot is empty", source)
        self.assertIn("SHAAR_DEVTOOLS_HEAP_PROFILER_TAKE_HEAP_SNAPSHOT = 77", source)
        self.assertIn("SHAAR_DEVTOOLS_HEAP_PROFILER_STOP_TRACKING_HEAP_OBJECTS = 79", source)
        self.assertNotIn('"command":65', source)
        self.assertNotIn("SHAAR_DEVTOOLS_HEAP_PROFILER_TAKE_HEAP_SNAPSHOT = 72", source)

    def test_patch_is_pinned_in_source_build(self):
        patches = json.loads(MANIFEST.read_text())["patches"]
        matching = [entry for entry in patches if entry["file"] == str(PATCH.relative_to(ROOT))]
        self.assertEqual(len(matching), 1)
        self.assertEqual(matching[0]["sha256"], hashlib.sha256(PATCH.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
