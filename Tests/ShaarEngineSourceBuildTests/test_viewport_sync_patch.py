# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Pin mirrored viewport color scheme, hover, and typing on the Shaar layer."""

from hashlib import sha256
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0062-shaar-devtools-viewport-sync.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"
LAYER = (
    ROOT
    / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/devtools/shaar_devtools_viewports.cc"
)
HIDDEN = ROOT / "ThirdParty/ChromiumEngine/patches/0028-shaar-devtools-hidden-panels.patch"
PRESETS = ROOT / "ThirdParty/ChromiumEngine/patches/0029-shaar-devtools-viewport-presets.patch"


class ViewportSyncPatchTests(unittest.TestCase):
    def test_sync_actions_are_explicit_and_bounded(self):
        source = PATCH.read_text()
        self.assertIn("Emulation.setEmulatedMedia", source)
        self.assertIn("prefers-color-scheme", source)
        self.assertIn('"mouseMoved"', source)
        self.assertIn("Input.dispatchKeyEvent", source)
        self.assertIn("ValidTypingText", source)
        self.assertIn('text.size() > 64', source)
        self.assertIn(r'\"colorScheme\":1,\"hover\":1,\"typing\":1', source)
        self.assertIn("unknown viewport action", source)

    def test_patch_is_pinned_in_source_build(self):
        patches = json.loads(MANIFEST.read_text())["patches"]
        matching = [entry for entry in patches if entry["file"] == str(PATCH.relative_to(ROOT))]
        self.assertEqual(len(matching), 1)
        self.assertEqual(matching[0]["sha256"], sha256(PATCH.read_bytes()).hexdigest())
        self.assertEqual(patches[-1]["file"], str(PATCH.relative_to(ROOT)))

    def test_patch_applies_after_the_preset_patch(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            destination = root / "chrome/browser/shaar/devtools"
            destination.mkdir(parents=True)
            (destination / "shaar_devtools_viewports.cc").write_bytes(LAYER.read_bytes())
            for patch in (HIDDEN, PRESETS, PATCH):
                subprocess.run(
                    [
                        "git", "apply", "--include=**/shaar_devtools_viewports.cc",
                        str(patch),
                    ],
                    check=True,
                    cwd=root,
                )
            applied = (destination / "shaar_devtools_viewports.cc").read_text()
            self.assertIn("SetColorSchemeAll", applied)
            self.assertIn("ApplyColorScheme", applied)


if __name__ == "__main__":
    unittest.main()
