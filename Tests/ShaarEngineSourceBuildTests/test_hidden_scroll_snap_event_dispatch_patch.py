"""Hidden scroll-snap events must not wait for an animation frame."""

import hashlib
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0143-blink-hidden-scroll-snap-event-dispatch.patch"


class HiddenScrollSnapEventDispatchPatchTests(unittest.TestCase):
    def test_patch_dispatches_hidden_scroll_snap_events_asynchronously(self):
        manifest = json.loads((ROOT / "ThirdParty/ChromiumEngine/source-build.json").read_text())
        entry = next(item for item in manifest["patches"] if item["file"] == str(PATCH.relative_to(ROOT)))
        content = PATCH.read_bytes()
        self.assertEqual(hashlib.sha256(content).hexdigest(), entry["sha256"])
        patch = content.decode()
        self.assertIn("EnqueueHiddenScrollSnapEvent", patch)
        self.assertIn("TaskType::kDOMManipulation", patch)
        self.assertNotIn("task_type.h", patch)
        self.assertIn("scrollsnapchange", patch)
        self.assertIn("scrollsnapchanging", patch)
        self.assertIn("if (hidden())", patch)
        self.assertIn("HiddenDocumentScrollSnapEventsDispatchWithoutAnimationFrame", patch)
        self.assertIn("EXPECT_TRUE(observer.Order().empty())", patch)
        self.assertIn("testing::ElementsAre(1, 2)", patch)


if __name__ == "__main__":
    unittest.main()
