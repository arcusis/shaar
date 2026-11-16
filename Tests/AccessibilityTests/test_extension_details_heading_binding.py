# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ExtensionDetailsHeadingBindingTests(unittest.TestCase):
    def test_detail_section_title_uses_heading_trait(self):
        source = (ROOT / "Sources/ArcusisBrowser/ProfileExtensionsSection.swift").read_text(
            encoding="utf-8"
        )
        section = source.split("private func detailSection(", 1)[1]

        self.assertIn("Text(title)", section)
        self.assertIn(".accessibilityAddTraits(Self.detailsHeadingTraits)", section)


if __name__ == "__main__":
    unittest.main()
