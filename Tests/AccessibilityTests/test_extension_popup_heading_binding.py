from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ExtensionPopupHeadingBindingTests(unittest.TestCase):
    def test_popup_name_uses_the_voiceover_heading_trait(self):
        source = (ROOT / "Sources/ArcusisBrowser/ExtensionPanel.swift").read_text(
            encoding="utf-8"
        )

        self.assertRegex(
            source,
            re.compile(
                r"Text\(context\.name\)[\s\S]{0,120}"
                r"\.accessibilityAddTraits\(Self\.popupTitleTraits\)"
            ),
        )


if __name__ == "__main__":
    unittest.main()
