# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""Restore regular autofill preferences after private Browser initialization."""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
LIFECYCLE = (
    ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/windows_tabs/"
    "shaar_windows_tabs_lifecycle.cc"
)


class PrivateBrowserAutofillRestoreOrderTests(unittest.TestCase):
    def test_private_autofill_snapshot_is_restored_after_browser_creation(self):
        source = LIFECYCLE.read_text()
        start = source.index("Browser* CreateHiddenBrowser(Profile* profile)")
        end = source.index("Profile* ResolveScope(", start)
        creation = source[start:end]
        browser_creation = creation.index("CreateBrowserWindow(std::move(params))")
        restoration = creation.index("RestorePrivateProfileAutofillPreferences(profile)")
        tab_observer = creation.index("Observer().ObserveTabStrip(browser)")
        self.assertLess(browser_creation, restoration)
        self.assertLess(restoration, tab_observer)


if __name__ == "__main__":
    unittest.main()
