from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class SidebarMediaPlayerAccessibilityFocusTests(unittest.TestCase):
    def test_voiceover_focus_on_mute_and_volume_keeps_slider_in_tree(self):
        source = (ROOT / "Sources/ArcusisBrowser/SidebarMediaPlayer.swift").read_text(
            encoding="utf-8"
        )
        mute_control = source.split(".focused($focusedControl, equals: .mute)", 1)[1].split(
            ".onHover", 1
        )[0]
        volume_control = source.split("private var volumeControl", 1)[1].split(
            "static func showsVolumeControl", 1
        )[0]

        self.assertIn("@AccessibilityFocusState", source)
        self.assertIn(".accessibilityFocused($accessibilityFocusedControl, equals: .mute)", mute_control)
        self.assertIn(".accessibilityFocused($accessibilityFocusedControl, equals: .volume)", volume_control)
        self.assertIn("accessibilityFocused: accessibilityFocusedControl != nil", source)
        self.assertIn("pointerRevealed || keyboardFocused || accessibilityFocused", source)


if __name__ == "__main__":
    unittest.main()
