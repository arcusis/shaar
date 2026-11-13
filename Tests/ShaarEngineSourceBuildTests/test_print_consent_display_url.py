# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""The print consent UI must not display credentials embedded in a page URL."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class PrintConsentDisplayURLTests(unittest.TestCase):
    def test_consent_sheet_uses_the_redacted_display_url(self):
        source = (ROOT / "Sources/ArcusisBrowser/PrintConsentSheet.swift").read_text()

        self.assertIn("Text(request.displayPageURL)", source)
        self.assertNotIn("Text(request.pageURL.absoluteString)", source)
