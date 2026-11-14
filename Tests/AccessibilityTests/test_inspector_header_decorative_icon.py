from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


class InspectorHeaderDecorativeIconTests(unittest.TestCase):
    def test_viewfinder_is_hidden_beside_the_inspector_heading(self):
        source = (ROOT / "Sources/ArcusisBrowser/InspectorPanel.swift").read_text(
            encoding="utf-8"
        )
        self.assertRegex(
            source,
            re.compile(
                r'Image\(systemName: "viewfinder"\)[\s\S]{0,120}'
                r"\.accessibilityHidden\(true\)"
            ),
        )
        self.assertRegex(
            source,
            re.compile(
                r'Text\(InspectorL10n\.string\("Inspector"\)\)[\s\S]{0,120}'
                r"\.accessibilityAddTraits\(Self\.titleAccessibilityTraits\)"
            ),
        )


if __name__ == "__main__":
    unittest.main()
