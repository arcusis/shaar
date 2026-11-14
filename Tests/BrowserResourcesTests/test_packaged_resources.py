# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "check_packaged_resources", ROOT / "scripts/check-packaged-resources.py")
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)

ALLOWED = """
let bundle = PackagedResourceBundle.resolve(
  named: "ArcusisBrowser_ArcusisBrowser", in: host, fallback: fallback ?? { .module })
"""
DIRECT = """
let url = Bundle.module.url(forResource: "runner", withExtension: "js")
"""
COMMENTED = """
/// A missing bundle must not call Bundle.module.
let bundle = PackagedResourceBundle.resolve(
  named: "Example", in: host, fallback: { .module }) // .module stays in the fallback
"""
BARE = """
func resourceBundle() -> Bundle { .module }
"""


class PackagedResourceSourceTests(unittest.TestCase):
    def test_invalid_utf8_source_reports_its_path_without_traceback(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / check.SHIPPING_SOURCE_ROOTS[0] / "Invalid.swift"
            source.parent.mkdir(parents=True)
            source.write_bytes(b"let value = \xff\n")

            with self.assertRaisesRegex(ValueError, "cannot read shipping Swift source.*Invalid.swift"):
                check.violations_in_tree(root)

    def test_repository_keeps_module_inside_the_packaged_helper(self):
        self.assertEqual(check.violations_in_tree(ROOT), [])

    def test_helper_fallback_is_allowed_and_direct_use_is_not(self):
        self.assertEqual(check.violations_in_source(ALLOWED, "Sources/ArcusisBrowser/Example.swift"), [])
        self.assertEqual(check.violations_in_source(COMMENTED, "Sources/BrowserCore/Example.swift"), [])
        direct = check.violations_in_source(DIRECT, "Sources/ArcusisBrowser/Example.swift")
        bare = check.violations_in_source(BARE, "Sources/BrowserCore/Example.swift")
        self.assertEqual(len(direct), 1)
        self.assertEqual(len(bare), 1)
        self.assertIn("PackagedResourceBundle.resolve", direct[0])

    def test_url_string_does_not_hide_module_reference_after_comment_marker(self):
        source = 'let url = URL(string: "https://example.invalid")!; _ = Bundle.module'
        violations = check.violations_in_source(source, "Sources/BrowserCore/Example.swift")
        self.assertEqual(len(violations), 1)

    def test_module_reference_inside_string_literal_is_ignored(self):
        source = 'let message = "Bundle.module is only available in development"'
        self.assertEqual(check.violations_in_source(source, "Sources/BrowserCore/Example.swift"), [])

    def test_module_reference_in_block_comments_is_ignored(self):
        source = """\
/* Bundle.module is only a comment */
/* A longer comment starts here
   Bundle.module remains comment text
   /* Swift block comments can nest. Bundle.module is still ignored. */
*/
let value = 1
"""
        self.assertEqual(check.violations_in_source(source, "Sources/BrowserCore/Example.swift"), [])

    def test_module_reference_in_interpolated_string_text_is_ignored(self):
        source = 'let message = "Bundle.module is text, not code: \\(label)"'
        self.assertEqual(check.violations_in_source(source, "Sources/BrowserCore/Example.swift"), [])

    def test_module_reference_in_string_interpolation_is_still_checked(self):
        source = 'let message = "Bundle: \\(Bundle.module)"'
        self.assertEqual(len(check.violations_in_source(source, "Sources/BrowserCore/Example.swift")), 1)

    def test_module_reference_in_raw_string_interpolation_is_still_checked(self):
        source = 'let message = #"Bundle: \\#(Bundle.module)"#'
        self.assertEqual(len(check.violations_in_source(source, "Sources/BrowserCore/Example.swift")), 1)

    def test_raw_string_embedded_quote_does_not_hide_following_code(self):
        source = 'let message = #"embedded " quote"#; _ = Bundle.module'
        violations = check.violations_in_source(source, "Sources/BrowserCore/Example.swift")
        self.assertEqual(len(violations), 1)

    def test_shipping_scan_skips_verification_sources(self):
        roots = set(check.SHIPPING_SOURCE_ROOTS)
        self.assertNotIn("Sources/ShaarVerification", roots)
        self.assertNotIn("Sources/ChromiumBridgeVerification", roots)
        files = [path.relative_to(ROOT).as_posix() for path in check.shipping_swift_files(ROOT)]
        self.assertTrue(any(path.startswith("Sources/ArcusisBrowser/") for path in files))
        self.assertFalse(any(path.startswith("Sources/ShaarVerification/") for path in files))


if __name__ == "__main__":
    unittest.main()
