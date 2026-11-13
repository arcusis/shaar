# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
PREFERENCES = REPO / "Sources/ArcusisBrowser/BrowserPreferencesStore.swift"


class PreferencesFileAccessTests(unittest.TestCase):
    def test_load_rejects_symlinks_and_applies_private_file_permissions(self):
        source = PREFERENCES.read_text()
        loader = source[source.index("private func load()") : source.index("private func preserveWithNotice")]

        self.assertIn(".isSymbolicLinkKey", loader)
        self.assertIn("values.isSymbolicLink != true", loader)
        self.assertIn("[.posixPermissions: 0o600]", loader)


if __name__ == "__main__":
    unittest.main()
