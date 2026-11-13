# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
IMPORTERS = REPO / "Sources/BrowserCore/BrowserProfileImporters.swift"


class PrivateProfilePathSecurityTests(unittest.TestCase):
    def test_private_profile_guard_resolves_symlinks_and_checks_ancestors(self):
        source = IMPORTERS.read_text()
        guard = source[
            source.index("private func rejectPrivateProfile") :
            source.index("private enum ChromiumHistoryReader")
        ]

        self.assertIn("url.resolvingSymlinksInPath().standardizedFileURL", guard)
        self.assertIn("resolved.pathComponents.map", guard)
        self.assertIn('marker == "guest" && !profileNames.contains(name)', guard)


if __name__ == "__main__":
    unittest.main()
