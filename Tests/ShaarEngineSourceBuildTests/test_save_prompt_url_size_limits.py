# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Bound save-prompt URLs before constructing an event payload."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/save_prompts/"
    "shaar_save_prompts.cc"
)


class SavePromptURLSizeLimitTests(unittest.TestCase):
    def test_invalid_or_oversized_page_and_origin_are_declined_before_emission(self):
        source = SOURCE.read_text()
        start = source.index("bool OfferSavePrompt(")
        end = source.index("shaar_error_code CompleteDecision(", start)
        offer = source[start:end]
        url_validation = offer[offer.index("const GURL page ="):]
        url_validation = url_validation[:url_validation.index("const std::string safe_detail")]

        self.assertIn("constexpr size_t kMaximumOriginBytes = 256;", source)
        self.assertIn("constexpr size_t kMaximumPageBytes = 2048;", source)
        self.assertIn("!page.is_valid() || !origin.is_valid()", url_validation)
        self.assertIn("page.spec().size() > kMaximumPageBytes", url_validation)
        self.assertIn("origin.spec().size() > kMaximumOriginBytes", url_validation)
        self.assertIn("return decline();", url_validation)


if __name__ == "__main__":
    unittest.main()
