# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO / "Sources/ArcusisBrowser/DownloadsFolderSource.swift"


class DownloadFolderContainmentTests(unittest.TestCase):
    def test_resolved_download_entries_must_remain_inside_the_selected_folder(self):
        source = SOURCE.read_text()
        refresh = source[source.index("func refresh()") : source.index("func item(")]

        self.assertIn("directory.resolvingSymlinksInPath().standardizedFileURL", refresh)
        self.assertIn("$0.url.path.hasPrefix(rootPath)", refresh)


if __name__ == "__main__":
    unittest.main()
