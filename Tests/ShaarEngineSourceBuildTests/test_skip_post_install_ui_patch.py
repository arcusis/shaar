# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep Chromium's post-install UI off when Shaar embeds the engine."""

from pathlib import Path
import hashlib
import json
import unittest


ROOT = Path(__file__).resolve().parents[2]
PATCH = ROOT / "ThirdParty/ChromiumEngine/patches/0163-shaar-skip-post-install-ui.patch"
MANIFEST = ROOT / "ThirdParty/ChromiumEngine/source-build.json"


class SkipPostInstallUIPatchTests(unittest.TestCase):
    def test_patch_returns_before_chromium_opens_a_visible_browser(self):
        source = PATCH.read_text()
        self.assertIn("chrome/browser/ui/extensions/extension_install_ui_desktop.cc", source)
        self.assertIn('+  if (base::CommandLine::ForCurrentProcess()->HasSwitch("shaar-embedder")) {', source)
        self.assertIn('+#include "base/command_line.h"', source)
        guard = source.index('HasSwitch("shaar-embedder")')
        self.assertLess(guard, source.index("if (!profile()) {"))

    def test_manifest_lists_the_patch_once_with_its_digest(self):
        entries = [entry for entry in json.loads(MANIFEST.read_text())["patches"]
                   if entry["file"].endswith("0163-shaar-skip-post-install-ui.patch")]
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["sha256"], hashlib.sha256(PATCH.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
