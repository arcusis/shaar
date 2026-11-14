# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Keep save-prompt page URL privacy cleanup behavior under direct test."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)
UNIT_TEST = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts_unittest.cc"
)


class SavePromptURLCleanupTests(unittest.TestCase):
    def test_cleanup_rejects_non_web_and_strips_sensitive_components(self):
        source = SOURCE.read_text()
        start = source.index("GURL CleanPageURLForSavePrompt(")
        end = source.index("namespace {", start)
        cleanup = source[start:end]
        self.assertIn("!url.SchemeIsHTTPOrHTTPS()", cleanup)
        for operation in (
            "ClearUsername()", "ClearPassword()", "ClearQuery()", "ClearRef()"
        ):
            self.assertIn(operation, cleanup)
        self.assertIn("url.ReplaceComponents(replacements)", cleanup)

    def test_cpp_regressions_cover_credentials_query_fragment_and_schemes(self):
        tests = UNIT_TEST.read_text()
        self.assertIn("PageURLRemovesCredentialsQueryAndFragment", tests)
        self.assertIn("PageURLRejectsNonWebSchemes", tests)
        self.assertIn("https://example.com/login", tests)
        self.assertIn('GURL("file:///tmp/page")', tests)
        self.assertIn('GURL("javascript:alert(1)")', tests)


if __name__ == "__main__":
    unittest.main()
