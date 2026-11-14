"""Hidden document resize events must not wait for another animation frame."""

import hashlib
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0141-blink-hidden-resize-event-dispatch.patch"


class HiddenResizeEventDispatchPatchTests(unittest.TestCase):
    def test_ordered_engine_patch_carries_hidden_resize_regression(self):
        manifest = json.loads((ROOT / "ThirdParty/ChromiumEngine/source-build.json").read_text())
        relative_patch = str(PATCH.relative_to(ROOT))
        entry = next(item for item in manifest["patches"] if item["file"] == relative_patch)
        content = PATCH.read_bytes()
        self.assertEqual(hashlib.sha256(content).hexdigest(), entry["sha256"])
        patch = content.decode()
        self.assertIn("if (!hidden())", patch)
        self.assertIn("EnqueueHiddenResizeEvent", patch)
        self.assertIn(
            " void Document::EnqueueResizeEvent() {\n+  if (!GetExecutionContext())\n+    return;",
            patch,
        )
        self.assertIn("TaskType::kDOMManipulation", patch)
        self.assertIn("HiddenDocumentResizeEventDispatchesWithoutAnimationFrame", patch)


if __name__ == "__main__":
    unittest.main()
