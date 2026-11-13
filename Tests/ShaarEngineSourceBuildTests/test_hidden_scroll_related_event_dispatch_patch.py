"""Hidden overscroll events share the asynchronous scroll dispatch path."""

import hashlib
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0144-blink-hidden-scroll-related-events.patch"


class HiddenScrollRelatedEventDispatchPatchTests(unittest.TestCase):
    def test_patch_keeps_hidden_overscroll_events_on_the_dom_task_path(self):
        manifest = json.loads((ROOT / "ThirdParty/ChromiumEngine/source-build.json").read_text())
        entry = next(item for item in manifest["patches"] if item["file"] == str(PATCH.relative_to(ROOT)))
        content = PATCH.read_bytes()
        self.assertEqual(hashlib.sha256(content).hexdigest(), entry["sha256"])
        patch = content.decode()
        self.assertIn("EnqueueHiddenScrollRelatedEvent", patch)
        self.assertIn(
            "+void ScriptedAnimationController::EnqueueHiddenScrollRelatedEvent(Event* event) {\n"
            "+  if (!GetExecutionContext())\n+    return;\n"
            "   if (!InsertToPerFrameEventsMap(event))",
            patch,
        )
        self.assertIn('AtomicString("overscroll")', patch)
        self.assertIn("EnqueueOverscrollEvent", patch)
        self.assertIn("HiddenDocumentScrollRelatedEventsDispatchWithoutAnimationFrame", patch)
        self.assertIn("+  GetDocument().body()->addEventListener(", patch)
        self.assertIn("+                                       GetDocument().body(),\n+                                       GetDocument().body(),", patch)
        self.assertIn("EXPECT_TRUE(observer.Order().empty())", patch)
        self.assertIn("testing::ElementsAre(1, 2, 3)", patch)


if __name__ == "__main__":
    unittest.main()
