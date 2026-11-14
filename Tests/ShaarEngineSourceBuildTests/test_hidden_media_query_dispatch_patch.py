"""Hidden media query listeners must not wait for another rendering frame."""

import hashlib
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0141-blink-hidden-resize-event-dispatch.patch"


class HiddenMediaQueryDispatchPatchTests(unittest.TestCase):
    def test_patch_dispatches_hidden_media_query_listeners_asynchronously(self):
        manifest = json.loads((ROOT / "ThirdParty/ChromiumEngine/source-build.json").read_text())
        relative_patch = str(PATCH.relative_to(ROOT))
        entry = next(item for item in manifest["patches"] if item["file"] == relative_patch)
        content = PATCH.read_bytes()
        self.assertEqual(hashlib.sha256(content).hexdigest(), entry["sha256"])
        patch = content.decode()
        self.assertIn("hidden_media_query_change_task_pending_", patch)
        self.assertIn("DispatchHiddenMediaQueryChangeTask", patch)
        self.assertIn("DispatchMediaQueryListEventsAndCallbacks", patch)
        self.assertIn("HiddenDocumentMediaQueryListListenersDispatchWithoutAnimationFrame", patch)


if __name__ == "__main__":
    unittest.main()
