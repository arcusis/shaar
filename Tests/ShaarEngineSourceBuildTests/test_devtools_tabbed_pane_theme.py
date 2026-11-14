# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Guard Shaar's DevTools tab header treatment."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
THEME = ROOT / "ThirdParty/ChromiumEngine/patches/0064-shaar-devtools-theme-157.patch"
TABBED_PANE = "third_party/devtools-frontend/src/front_end/ui/legacy/tabbedPane.css"


def tabbed_pane_patch() -> str:
    patch = THEME.read_text()
    section = patch.split(f"--- a/{TABBED_PANE}\n", 1)[1]
    return section.split("\n--- a/", 1)[0]


class DevToolsTabbedPaneThemeTests(unittest.TestCase):
    def test_selected_tab_uses_shaar_tokens_without_overriding_forced_colors(self):
        source = tabbed_pane_patch()
        self.assertIn("@media (forced-colors: none)", source)
        self.assertIn(".tabbed-pane-header-tab.selected", source)
        self.assertIn("color: var(--sys-color-on-tonal-container);", source)
        self.assertIn("background: var(--sys-color-tonal-container);", source)
        self.assertIn("inset 0 3px 0 var(--sys-color-primary)", source)
        self.assertIn("font-weight: 600;", source)
        self.assertIn(":not(.vertical-tab-layout)", source)


if __name__ == "__main__":
    unittest.main()
