from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class SymbolPickerHeadingBindingTests(unittest.TestCase):
    def test_symbol_section_title_uses_heading_trait(self):
        source = (ROOT / "Sources/ArcusisBrowser/SymbolPicker.swift").read_text(
            encoding="utf-8"
        )
        title = source.split("ForEach(SymbolCatalog.sections(matching: query)", 1)[1].split(
            "LazyVGrid", 1
        )[0]

        self.assertIn("Text(SettingsL10n.string(section.name))", title)
        self.assertIn(".accessibilityAddTraits(Self.sectionHeaderTraits)", title)


if __name__ == "__main__":
    unittest.main()
