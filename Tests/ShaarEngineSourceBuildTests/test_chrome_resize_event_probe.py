"""The native viewport probe checks page resize events for chrome-driven layout changes."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ChromeResizeEventProbeTests(unittest.TestCase):
    def test_sidebar_and_find_layout_changes_require_page_resize_delivery(self):
        source = (ROOT / "Sources/ShaarVerification/NativeHostProbe.swift").read_text()
        transitions = (
            "after: firstNormalBeforeChrome.resizeEventCount",
            "after: sidebarHidden.resizeEventCount",
            "after: sidebarShown.resizeEventCount",
            "after: findOpen.resizeEventCount",
        )
        for transition in transitions:
            with self.subTest(transition=transition):
                self.assertIn(transition, source)
        self.assertIn("from: firstNormalBeforeChrome.resizeEventCount, to: sidebarHidden.resizeEventCount", source)
        self.assertIn("from: sidebarHidden.resizeEventCount, to: sidebarShown.resizeEventCount", source)
        self.assertIn("from: sidebarShown.resizeEventCount, to: findOpen.resizeEventCount", source)
        self.assertIn("from: findOpen.resizeEventCount, to: findClosed.resizeEventCount", source)


if __name__ == "__main__":
    unittest.main()
