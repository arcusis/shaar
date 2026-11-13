# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import hashlib
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0140-blink-hidden-scroll-event-dispatch.patch"


class HiddenScrollEventDispatchPatchTests(unittest.TestCase):
    def test_ordered_engine_patch_carries_the_hidden_scroll_regression(self):
        manifest = json.loads((ROOT / "ThirdParty/ChromiumEngine/source-build.json").read_text())
        relative_patch = str(PATCH.relative_to(ROOT))
        entry = next(item for item in manifest["patches"] if item["file"] == relative_patch)
        content = PATCH.read_bytes()
        self.assertEqual(hashlib.sha256(content).hexdigest(), entry["sha256"])
        patch = content.decode()
        self.assertIn("if (hidden())", patch)
        self.assertIn("EnqueueHiddenScrollEvent", patch)
        self.assertIn("TaskType::kDOMManipulation", patch)
        self.assertIn("HiddenDocumentScrollEventDispatchesWithoutAnimationFrame", patch)


if __name__ == "__main__":
    unittest.main()
