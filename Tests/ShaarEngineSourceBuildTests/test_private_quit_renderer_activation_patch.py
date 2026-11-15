# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Apply the 157 quit-cancel hook to the upstream close manager."""

from pathlib import Path
import base64
import json
import subprocess
import tempfile
import unittest
import urllib.request


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0044-shaar-quit-cancellation-callback.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"
DUPLICATE = ROOT / "ThirdParty/ChromiumEngine/patches/0061-shaar-private-quit-renderer-activation.patch"
LAYER = ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar"
TAG_URL = (
    "https://chromium.googlesource.com/chromium/src/+/"
    "refs/tags/157.0.8103.51/chrome/browser/lifetime/"
    "browser_close_manager.cc?format=TEXT"
)
RELEASE_QUIT_EXPORTS = (
    "_shaar_test_quit_dialog_audit",
    "_shaar_test_quit_dialog_cancel",
    "_shaar_test_quit_dialog_prepare",
    "_shaar_test_quit_dialog_release",
    "_shaar_test_renderer_activate",
)


def fetch_tag_close_manager() -> bytes:
    request = urllib.request.Request(TAG_URL, headers={"User-Agent": "shaar-source-build-test"})
    with urllib.request.urlopen(request, timeout=60) as response:
        payload = response.read()
    return base64.b64decode(payload)


class PrivateQuitRendererActivationPatchTests(unittest.TestCase):
    def test_157_hook_is_pinned_in_the_157_patch_list(self):
        files = [entry["file"] for entry in json.loads(MANIFEST.read_text())["patches"]]
        self.assertIn(str(PATCH.relative_to(ROOT)), files)
        self.assertNotIn(str(DUPLICATE.relative_to(ROOT)), files)
        self.assertIn("ResetBeforeUnloadForShutdown", PATCH.read_text())

    def test_patch_applies_to_the_157_close_manager_tag(self):
        source = fetch_tag_close_manager()
        self.assertIn(b"ResetBeforeUnloadForShutdown", source)
        self.assertNotIn(b"ResetTryToCloseWindow", source)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            dest = root / "chrome/browser/lifetime/browser_close_manager.cc"
            dest.parent.mkdir(parents=True)
            dest.write_bytes(source)
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            checked = subprocess.run(
                ["git", "apply", "--check", str(PATCH)],
                cwd=root, capture_output=True, text=True,
            )
            self.assertEqual(checked.returncode, 0, checked.stderr)
            applied = subprocess.run(
                ["git", "apply", str(PATCH)],
                cwd=root, capture_output=True, text=True,
            )
            self.assertEqual(applied.returncode, 0, applied.stderr)
            patched = dest.read_text()
        self.assertIn("shaar::lifecycle::EngineQuitCancelled", patched)
        self.assertIn("ResetBeforeUnloadForShutdown", patched)
        self.assertNotIn("ResetTryToCloseWindow", patched)
        self.assertLess(
            patched.index("EngineQuitCancelled();"),
            patched.index("ResetBeforeUnloadForShutdown();"),
        )

    def test_release_exports_omit_the_quit_probe_symbols(self):
        manifest = json.loads(MANIFEST.read_text())
        release = (LAYER / "shaar_engine.exports").read_text().split()
        probe = (LAYER / "shaar_engine_quit_probe.exports").read_text().split()
        build = (LAYER / "BUILD.gn").read_text()
        for symbol in RELEASE_QUIT_EXPORTS:
            self.assertNotIn(symbol, manifest["requiredExports"])
            self.assertNotIn(symbol, release)
        self.assertEqual(list(RELEASE_QUIT_EXPORTS), probe)
        self.assertIn("shaar_enable_quit_probe_hooks = false", build)
        self.assertIn('inputs += [ "shaar_engine_quit_probe.exports" ]', build)
        self.assertIn("if (shaar_enable_quit_probe_hooks)", build)
        self.assertIn("if (!shaar_enable_quit_probe_hooks)", build)


if __name__ == "__main__":
    unittest.main()
