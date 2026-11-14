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
        self.assertIn("window.addEventListener('blur'", source)
        self.assertIn("NSWindowDidResignKeyNotification", source)
        self.assertIn('window.pageFocusCount', source)
        self.assertIn('window.pageBlurCount', source)

    def test_rejected_native_focus_does_not_emit_page_focus(self):
        source = (ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/windows_tabs/shaar_page_view_host_unittest.mm").read_text()
        self.assertIn("RejectedNativeFocusDoesNotFocusWebContents", source)
        self.assertIn("target.rejectFirstResponder = YES;", source)
        self.assertIn("EXPECT_FALSE(host.Focus(tab));", source)
        self.assertIn('"window.pageFocusCount").ExtractInt(), 0', source)

    def test_repeated_native_focus_does_not_duplicate_page_focus(self):
        source = (ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/windows_tabs/shaar_page_view_host_unittest.mm").read_text()
        self.assertIn("RepeatedNativeFocusKeepsPageFocusEventIdempotent", source)
        self.assertEqual(source.count("ASSERT_TRUE(host.Focus(tab));"), 3)
        self.assertIn('"window.pageFocusCount").ExtractInt(), 1', source)


if __name__ == "__main__":
    unittest.main()
