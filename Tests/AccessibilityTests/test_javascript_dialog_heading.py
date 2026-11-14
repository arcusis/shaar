from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


class JavaScriptDialogHeadingTests(unittest.TestCase):
    def test_dialog_title_attaches_heading_trait(self):
        source = (ROOT / "Sources/ArcusisBrowser/JavaScriptDialogSheet.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            "static let titleAccessibilityTraits: AccessibilityTraits = .isHeader", source
        )
        self.assertRegex(
            source,
            re.compile(
                r"Text\(title\)\.font\(\.title2\.weight\(\.semibold\)\)"
                r"[\s\S]{0,120}"
                r"\.accessibilityAddTraits\(Self\.titleAccessibilityTraits\)"
            ),
        )


if __name__ == "__main__":
    unittest.main()
