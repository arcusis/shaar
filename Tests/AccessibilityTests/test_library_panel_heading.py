from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


class LibraryPanelHeadingTests(unittest.TestCase):
    def test_library_section_title_attaches_heading_trait(self):
        source = (ROOT / "Sources/ArcusisBrowser/LibraryPanel.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn("static var titleAccessibilityTraits: AccessibilityTraits { .isHeader }", source)
        self.assertRegex(
            source,
            re.compile(
                r"Text\(section\.title\)[\s\S]{0,160}"
                r"\.accessibilityAddTraits\(Self\.titleAccessibilityTraits\)"
            ),
        )


if __name__ == "__main__":
    unittest.main()
