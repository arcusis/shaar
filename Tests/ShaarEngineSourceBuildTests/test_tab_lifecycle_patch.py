# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Sleeping tabs live in the layer. Patch 0062 is the same change for a tree that already applied patch 0058."""

from pathlib import Path
import hashlib
import json
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


def patch_target_files():
    return sorted({
        line[6:]
        for line in PATCH.read_text().splitlines()
        if line.startswith("+++ b/")
    })


def patch_origin_layer_files():
    patch_path = str(PATCH.relative_to(ROOT))
    revision = subprocess.run(
        ["git", "-C", str(ROOT), "log", "-1", "--format=%H", "--diff-filter=A", "--", patch_path],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    files = {}
    for path in patch_target_files():
        source_path = f"ThirdParty/ChromiumEngine/layer/{path}"
        content = subprocess.run(
            ["git", "-C", str(ROOT), "show", f"{revision}:{source_path}"],
            capture_output=True, check=True,
        ).stdout
        files[path] = content
    return files


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
        self.assertEqual(listed.count(str(PATCH.relative_to(ROOT))), 0)
        self.assertNotIn("0061-shaar-tab-lifecycle.patch", "\n".join(listed))
        self.assertIn("SHAAR_OP_TAB_DISCARD = 208",
                      (LAYER / "chrome/browser/shaar/public/shaar_engine.h").read_text())

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
        shallow = subprocess.run(
            ["git", "-C", str(ROOT), "rev-parse", "--is-shallow-repository"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        origin = subprocess.run(
            ["git", "-C", str(ROOT), "log", "-1", "--format=%H", "--diff-filter=A",
             "--", str(PATCH.relative_to(ROOT))],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        head = subprocess.run(
            ["git", "-C", str(ROOT), "rev-parse", "HEAD"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        if shallow == "true" and origin == head:
            self.skipTest("patch origin layer requires full git history")
        expected_files = patch_origin_layer_files()
        with tempfile.TemporaryDirectory() as raw:
            tree = Path(raw)
            current = tree / "current"
            for name, contents in expected_files.items():
                path = current / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(contents)
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
            subprocess.run(
                ["git", "-C", str(current), "apply", str(PATCH)],
                check=True)
            for name, contents in expected_files.items():
                self.assertEqual((current / name).read_bytes(), contents, name)


if __name__ == "__main__":
    unittest.main()
