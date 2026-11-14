from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ExtensionManagerHeadingBindingTests(unittest.TestCase):
    def test_manager_title_uses_the_voiceover_heading_trait(self):
        source = (ROOT / "Sources/ArcusisBrowser/ExtensionPanel.swift").read_text(
            encoding="utf-8"
        )
        title = source.split('Text(PanelsL10n.string("Extensions"))', 1)[1].split(
            'Text(PanelsL10n.format("%@ profile"', 1
        )[0]

        self.assertIn(".accessibilityAddTraits(Self.headingTraits)", title)


if __name__ == "__main__":
    unittest.main()
