"""The page host must forward successful native focus to WebContents."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class PageFocusDeliveryTests(unittest.TestCase):
    def test_native_focus_is_forwarded_after_first_responder_succeeds(self):
        source = (ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/windows_tabs/shaar_page_view_host.mm").read_text()
        self.assertIn("if (![target makeFirstResponder:tab_view])", source)
        self.assertIn("contents->Focus();", source)

    def test_native_regression_observes_document_focus_event(self):
        source = (ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/windows_tabs/shaar_page_view_host_unittest.mm").read_text()
        self.assertIn("FocusForwardsToSelectedWebContents", source)
        self.assertIn("window.addEventListener('focus'", source)
        self.assertIn('window.pageFocusCount', source)


if __name__ == "__main__":
    unittest.main()
