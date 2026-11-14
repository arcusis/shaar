# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Pending reloads preserve the requested cache mode in LoadURLParams."""

from pathlib import Path
import hashlib
import json
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/navigation/shaar_navigation.cc"
)
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"
LAYER_PATH = "chrome/browser/shaar/navigation/shaar_navigation.cc"


def layer_digest(files):
    digest = hashlib.sha256()
    for name, file_digest in sorted(files.items()):
        digest.update(name.encode("utf-8") + b"\0" + file_digest.encode("ascii") + b"\n")
    return digest.hexdigest()


class PendingReloadCacheModeTests(unittest.TestCase):
    def test_pending_reload_preserves_normal_and_bypassing_cache_modes(self):
        source = SOURCE.read_text()
        pending = source.split(
            "content::NavigationEntry* pending_entry = controller->GetPendingEntry();", 1
        )[1].split("\n  }", 1)[0]
        self.assertIn("const GURL target = ReloadTargetURL(", pending)
        self.assertIn("pending_entry->GetURL()", pending)
        self.assertIn("content::NavigationController::LoadURLParams params(target)", pending)
        self.assertIn("params.transition_type = ui::PAGE_TRANSITION_RELOAD", pending)
        self.assertIn("controller->LoadURLWithParams(params)", pending)
        self.assertIn(
            "params.reload_type = bypass_cache ? content::ReloadType::BYPASSING_CACHE",
            pending)
        self.assertIn(": content::ReloadType::NORMAL;", pending)
        self.assertIn("params.should_replace_current_entry = true", pending)

    def test_layer_hashes_pin_the_reload_implementation(self):
        layer = json.loads(MANIFEST.read_text())["layer"]
        files = layer["files"]
        self.assertEqual(
            files[LAYER_PATH],
            hashlib.sha256(SOURCE.read_bytes()).hexdigest())
        self.assertEqual(layer_digest(files), layer["sha256"])


if __name__ == "__main__":
    unittest.main()
