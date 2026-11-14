from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class SiteControlsHeadingBindingTests(unittest.TestCase):
    def test_section_title_applies_its_accessibility_heading_trait(self):
        source = (ROOT / "Sources/ArcusisBrowser/SiteControlsPanel.swift").read_text(
            encoding="utf-8"
        )
        section_title = source.split("struct SiteSectionTitle: View", 1)[1].split(
            "struct SiteExtensionsSection: View", 1
        )[0]

        self.assertIn("ShellL10n.text(title)", section_title)
        self.assertIn(".accessibilityAddTraits(Self.accessibilityTraits)", section_title)


if __name__ == "__main__":
    unittest.main()
