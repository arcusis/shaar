"""Hidden media-query tasks must ignore destroyed execution contexts."""

import hashlib
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0141-blink-hidden-resize-event-dispatch.patch"


class HiddenMediaQueryContextGuardTests(unittest.TestCase):
    def test_enqueue_and_deferred_dispatch_guard_the_execution_context(self):
        manifest = json.loads((ROOT / "ThirdParty/ChromiumEngine/source-build.json").read_text())
        relative_patch = str(PATCH.relative_to(ROOT))
        entry = next(item for item in manifest["patches"] if item["file"] == relative_patch)
        content = PATCH.read_bytes()
        self.assertEqual(hashlib.sha256(content).hexdigest(), entry["sha256"])
        patch = content.decode()

        enqueue = patch.split("void Document::EnqueueMediaQueryChangeListeners", 1)[1].split(
            "void Document::DispatchHiddenMediaQueryChangeTask", 1
        )[0]
        self.assertLess(
            enqueue.index("+  if (!GetExecutionContext())"),
            enqueue.index("scripted_animation_controller_->EnqueueMediaQueryChangeListeners"),
        )

        dispatch = patch.split("void Document::DispatchHiddenMediaQueryChangeTask", 1)[1]
        self.assertIn(
            "+  if (!GetExecutionContext())\n+    return;", dispatch
        )
        self.assertIn("DispatchMediaQueryListEventsAndCallbacks", dispatch)


if __name__ == "__main__":
    unittest.main()
