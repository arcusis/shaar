import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE = ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/devtools/shaar_devtools.cc"


class WebStoreCalloutProbeTests(unittest.TestCase):
    def test_persistent_store_callout_does_not_block_trusted_add_click(self):
        source = SOURCE.read_text()
        self.assertIn("location.origin!=='https://chromewebstore.google.com'", source)
        self.assertIn("t?.tagName==='IFRAME'&&t.name==='callout'", source)
        self.assertIn("t.getAttribute('src')==='about:blank'", source)
        self.assertIn("shaar-probe-store-callout", source)
        self.assertIn("div:has(>iframe[name=", source)
        self.assertIn("pointer-events:none!important", source)
        self.assertIn("covered:!e.contains(document.elementFromPoint(x,y))", source)
        self.assertIn("TrustedWebStoreClickAllowed(testing_enabled, owned_root, selected,", source)


if __name__ == "__main__":
    unittest.main()
