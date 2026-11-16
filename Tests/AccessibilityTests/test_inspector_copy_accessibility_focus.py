# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class InspectorCopyAccessibilityFocusTests(unittest.TestCase):
    def test_section_and_property_copy_buttons_follow_accessibility_focus(self):
        source = (ROOT / "Sources/ArcusisBrowser/InspectorPanelComponents.swift").read_text(
            encoding="utf-8"
        )
        self.assertEqual(source.count("@AccessibilityFocusState"), 2)
        self.assertEqual(source.count(".accessibilityFocused($copyAccessibilityFocused)"), 2)
        self.assertEqual(source.count("InspectorCopyButtonVisibility.isVisible("), 2)
        self.assertIn("hovered || keyboardFocused || accessibilityFocused", source)


if __name__ == "__main__":
    unittest.main()
