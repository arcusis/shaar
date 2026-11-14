from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ImportPreviewHeadingBindingTests(unittest.TestCase):
    def test_preview_title_uses_the_voiceover_heading_trait(self):
        source = (ROOT / "Sources/ArcusisBrowser/BrowserImportPreviewView.swift").read_text(
            encoding="utf-8"
        )
        title = source.split(
            'Text(PanelsL10n.string("Import from another browser"))', 1
        )[1].split("if let error", 1)[0]

        self.assertIn(".accessibilityAddTraits(Self.headingTraits)", title)


if __name__ == "__main__":
    unittest.main()
