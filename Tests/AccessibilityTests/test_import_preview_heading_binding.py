# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ImportPreviewHeadingBindingTests(unittest.TestCase):
    def test_preview_title_uses_the_voiceover_heading_trait(self):
        source = (ROOT / "Sources/ArcusisBrowser/BrowserImportPreviewView.swift").read_text(
            encoding="utf-8"
        )
        title = source.split(
            'Text(PanelsL10n.string("Import from another browser"))', 1
        )[1].split("if let error", 1)[0]

        self.assertIn(".accessibilityAddTraits(Self.headingTraits)", title)


if __name__ == "__main__":
    unittest.main()
