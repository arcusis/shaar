# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Sleeping tabs live in the layer. Patch 0062 is the same change for a tree that already applied patch 0058."""

from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
LAYER = ROOT / "ThirdParty/ChromiumEngine/layer"
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0062-shaar-tab-lifecycle.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"


def layer_digest(files):
    digest = hashlib.sha256()
    for name, file_digest in sorted(files.items()):
        digest.update(name.encode("utf-8") + b"\0" + file_digest.encode("ascii") + b"\n")
    return digest.hexdigest()


class TabLifecyclePatchTests(unittest.TestCase):
    def test_discard_freeze_and_wake_are_in_the_patch(self):
        source = PATCH.read_text()
        self.assertIn("SHAAR_OP_TAB_DISCARD = 208", source)
        self.assertIn("SHAAR_OP_TAB_FREEZE = 209", source)
        self.assertIn("SHAAR_OP_TAB_WAKE = 210", source)
        self.assertIn("SHAAR_OP_TAB_LIFECYCLE_GET = 211", source)
        self.assertIn("unit->DiscardTab(reason, 0)", source)
        self.assertIn("contents->SetPageFrozen(true)", source)
        self.assertIn("contents->SetPageFrozen(false)", source)
        self.assertIn("unit->MaybeLoad()", source)
        self.assertIn("AboutToBeDiscarded", source)
        self.assertIn('payload.Set("kind", "lifecycle")', source)
        self.assertIn("shaar_tab_lifecycle_register", source)
        self.assertIn("-#define SHAAR_ENGINE_ABI_MINOR 10u", source)
        self.assertIn("+#define SHAAR_ENGINE_ABI_MINOR 11u", source)
        self.assertIn("TabSleepBlock", source)
        self.assertIn("TabDiscardBlock", source)
        self.assertIn("NeedsTemporaryHideForWake", source)
        self.assertNotIn("unit->GetWebContents()", source)
        self.assertIn("discard reason is not available to the app", source)
        self.assertIn("contents->WasHidden()", source)
        self.assertIn("contents->SetPageFrozen(false)", source)
        self.assertIn("UnbindTab", source)
        self.assertIn("RetargetWebContents(nullptr)", source)
        self.assertNotIn("tab->Observe(", source)
        self.assertIn("EmitInitialState", source)
        self.assertNotIn("RegisterModule", source)

    def test_patch_is_not_applied_twice(self):
        manifest = json.loads(MANIFEST.read_text())
        listed = [entry["file"] for entry in manifest["patches"]]
        self.assertNotIn(str(PATCH.relative_to(ROOT)), listed)
        self.assertNotIn("0062-shaar-tab-lifecycle.patch", "\n".join(listed))
        self.assertNotIn("0061-shaar-tab-lifecycle.patch", "\n".join(listed))

    def test_layer_hashes_match_the_files(self):
        manifest = json.loads(MANIFEST.read_text())
        files = manifest["layer"]["files"]
        self.assertIn("chrome/browser/shaar/tab_lifecycle/shaar_tab_lifecycle.cc", files)
        self.assertIn("chrome/browser/shaar/tab_lifecycle/shaar_tab_lifecycle.h", files)
        self.assertIn(
            "chrome/browser/shaar/tab_lifecycle/shaar_tab_lifecycle_unittest.cc", files)
        for name, file_digest in files.items():
            path = LAYER / name
            self.assertTrue(path.is_file(), name)
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), file_digest, name)
        self.assertEqual(layer_digest(files), manifest["layer"]["sha256"])

    def test_patch_round_trips_onto_the_previous_layer(self):
        with tempfile.TemporaryDirectory() as raw:
            tree = Path(raw)
            current = tree / "current"
            shutil.copytree(LAYER / "chrome", current / "chrome")
            reverse = subprocess.run(
                ["git", "-C", str(current), "apply", "--reverse", "--check", str(PATCH)],
                capture_output=True, text=True)
            self.assertEqual(reverse.returncode, 0, reverse.stderr)
            subprocess.run(
                ["git", "-C", str(current), "apply", "--reverse", str(PATCH)],
                check=True)
            forward = subprocess.run(
                ["git", "-C", str(current), "apply", "--check", str(PATCH)],
                capture_output=True, text=True)
            self.assertEqual(forward.returncode, 0, forward.stderr)
            previous = tree / "previous"
            shutil.copytree(current / "chrome", previous / "chrome")
            subprocess.run(
                ["git", "-C", str(current), "apply", str(PATCH)],
                check=True)
            difference = subprocess.run(
                ["diff", "-ru", str(current / "chrome/browser/shaar"), str(LAYER / "chrome/browser/shaar")],
                capture_output=True, text=True)
            self.assertEqual(difference.returncode, 0, difference.stdout)


if __name__ == "__main__":
    unittest.main()
