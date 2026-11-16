# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


class SidebarTabLabelBindingTests(unittest.TestCase):
    def test_select_button_uses_the_accessible_tab_title_fallback(self):
        source = (ROOT / "Sources/ArcusisBrowser/SidebarTabRow.swift").read_text(
            encoding="utf-8"
        )

        self.assertRegex(
            source,
            re.compile(
                r"\.buttonStyle\(\.plain\)[\s\S]{0,240}"
                r"\.accessibilityLabel\(\s*"
                r"SidebarTabTitle\.accessibilityLabel\("
                r"\s*title: title, address: address, isSleeping: isSleeping, isPinned: isPinned\)"
            ),
        )


if __name__ == "__main__":
    unittest.main()
