"""Hidden visual viewport events must not wait for an animation frame."""

import hashlib
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0142-blink-hidden-visual-viewport-events.patch"


class HiddenVisualViewportEventDispatchPatchTests(unittest.TestCase):
    def test_ordered_engine_patch_carries_hidden_event_regression(self):
        manifest = json.loads((ROOT / "ThirdParty/ChromiumEngine/source-build.json").read_text())
        relative_patch = str(PATCH.relative_to(ROOT))
        entry = next(item for item in manifest["patches"] if item["file"] == relative_patch)
        content = PATCH.read_bytes()
        self.assertEqual(hashlib.sha256(content).hexdigest(), entry["sha256"])
        patch = content.decode()
        self.assertEqual(patch.count("EnqueueVisualViewportEvent(event)"), 3)
        self.assertIn("hidden_visual_viewport_event_task_pending_", patch)
        self.assertIn("TaskType::kDOMManipulation", patch)
        self.assertIn("event->target() == target", patch)
        self.assertIn("HiddenDocumentVisualViewportEventsDispatchWithoutAnimationFrame", patch)
        for event_type in ("scroll", "scrollend", "resize"):
            self.assertIn(f'AtomicString("{event_type}")', patch)
        for method in (
            "EnqueueVisualViewportScrollEvent",
            "EnqueueVisualViewportScrollEndEvent",
            "EnqueueVisualViewportResizeEvent",
        ):
            self.assertIn(method, patch)


if __name__ == "__main__":
    unittest.main()
