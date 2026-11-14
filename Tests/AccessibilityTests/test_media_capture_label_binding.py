from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class MediaCaptureLabelBindingTests(unittest.TestCase):
    def test_capture_menu_has_a_counted_voiceover_label(self):
        source = (ROOT / "Sources/ArcusisBrowser/MediaCaptureIndicator.swift").read_text(
            encoding="utf-8"
        )
        menu = source.split("Menu {", 1)[1].split("private var captureSymbol", 1)[0]

        self.assertIn(
            '.accessibilityLabel(PanelsL10n.plural("%d active capture tabs", count: capturingTabs.count))',
            menu,
        )


if __name__ == "__main__":
    unittest.main()
