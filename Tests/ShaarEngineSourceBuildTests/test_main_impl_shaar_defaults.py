# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Guard Shaar-only DevTools defaults in the Chromium 157 patch."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
THEME = ROOT / "ThirdParty/ChromiumEngine/patches/0064-shaar-devtools-theme-157.patch"
MAIN_IMPL_PATH = "--- a/third_party/devtools-frontend/src/front_end/entrypoints/main/MainImpl.ts\n"


def main_impl_patch() -> str:
    patch = THEME.read_text()
    section = patch.split(MAIN_IMPL_PATH, 1)[1]
    return section.split("\n--- a/", 1)[0]


class ShaarDevToolsDefaultsTests(unittest.TestCase):
    def test_apca_defaults_on_without_overriding_a_saved_preference(self):
        source = main_impl_patch()
        self.assertIn("if (config.isShaarEmbedder && !('apca' in prefs)) {", source)
        self.assertIn(
            "this.#universe.settings.resolve(SDK.SDKSettings.apcaSettingDescriptor).set(true);",
            source,
        )

    def test_google_only_mcp_menu_entry_is_gated_for_other_embedders(self):
        source = main_impl_patch()
        guard = "if (!Root.Runtime.hostConfig.isShaarEmbedder) {"
        self.assertIn(guard, source)
        guarded_menu = source.split(guard, 1)[1].split("\n+    }", 1)[0]
        self.assertIn("getChromeDevToolsForAgents", guarded_menu)
        self.assertIn("chrome-devtools-mcp", guarded_menu)


if __name__ == "__main__":
    unittest.main()
