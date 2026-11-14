# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
COMMAND_SEARCH = REPO / "Sources/BrowserCore/CommandSearch.swift"


class NavigationSecurityTests(unittest.TestCase):
    def test_web_navigation_rejects_authority_credentials(self):
        source = COMMAND_SEARCH.read_text()
        policy = source[
            source.index("public static func isWebURL") :
            source.index("public static func destination")
        ]

        self.assertIn("url.user == nil && url.password == nil", policy)


if __name__ == "__main__":
    unittest.main()
