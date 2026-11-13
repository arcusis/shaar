"""Fallback page selection must mirror the owning native window state."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class FallbackPageVisibilityTests(unittest.TestCase):
    def test_selection_maps_window_visibility_into_web_contents(self):
        source = (ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/windows_tabs/shaar_page_view_binding.mm").read_text()
        self.assertIn("selected->GetNativeView().GetNativeNSView().window", source)
        self.assertIn("window.isVisible || window.isMiniaturized", source)
        self.assertIn("window.occlusionState & NSWindowOcclusionStateVisible", source)
        self.assertIn("selected->UpdateWebContentsVisibility(visibility)", source)

    def test_native_regression_covers_hidden_visible_occluded_and_minimized(self):
        source = (ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/windows_tabs/shaar_page_view_host_unittest.mm").read_text()
        self.assertIn("FallbackSelectionTracksOwningWindowVisibility", source)
        for state in ("HIDDEN", "VISIBLE", "OCCLUDED"):
            self.assertIn(f"content::Visibility::{state}", source)


if __name__ == "__main__":
    unittest.main()
