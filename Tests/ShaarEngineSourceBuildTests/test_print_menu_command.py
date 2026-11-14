# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

"""The browser File > Print command stays bound to the selected live native tab."""

from pathlib import Path
import hashlib
import json
import unittest


ROOT = Path(__file__).resolve().parents[2]


class PrintMenuCommandTests(unittest.TestCase):
    def test_native_tab_print_symbol_is_optional_and_exported(self):
        header = (ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/public/shaar_engine.h").read_text()
        exports = (ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/shaar_engine.exports").read_text()
        source = (ROOT / "ThirdParty/ChromiumEngine/layer/chrome/browser/shaar/windows_tabs/shaar_windows_tabs_lifecycle.cc").read_text()
        optional = json.loads((ROOT / "ThirdParty/ChromiumEngine/abi-optional-symbols.json").read_text())
        manifest = json.loads((ROOT / "ThirdParty/ChromiumEngine/source-build.json").read_text())

        self.assertIn("shaar_tab_print(", header)
        self.assertIn("_shaar_tab_print", exports)
        self.assertEqual(optional["symbols"]["shaar_tab_print"], "engine-157.0.8103.51-shaar.36")
        self.assertIn("browser->GetTabStripModel()->GetActiveWebContents() != contents", source)
        self.assertIn("manager->BasicPrint(main_frame)", source)
        self.assertIn("PrintViewManager::CreateForWebContents(contents)", source)
        layer = manifest["layer"]
        for name in (
            "chrome/browser/shaar/public/shaar_engine.h",
            "chrome/browser/shaar/shaar_engine.exports",
            "chrome/browser/shaar/windows_tabs/shaar_windows_tabs_lifecycle.cc",
        ):
            actual = hashlib.sha256((ROOT / "ThirdParty/ChromiumEngine/layer" / name).read_bytes()).hexdigest()
            self.assertEqual(layer["files"][name], actual)
        digest = hashlib.sha256("".join(
            f"{name}\0{value}\n" for name, value in sorted(layer["files"].items())
        ).encode()).hexdigest()
        self.assertEqual(layer["sha256"], digest)

    def test_file_menu_print_routes_through_selected_bridge_tab(self):
        host = (ROOT / "Sources/ArcusisBrowser/NativeBrowserHost.swift").read_text()
        private_host = (ROOT / "Sources/ArcusisBrowser/PrivateBrowserHost.swift").read_text()
        bridge = (ROOT / "Sources/ChromiumBridge/ChromiumShaarBackend.mm").read_text()
        tests = (ROOT / "Tests/BrowserAppTests/NativeMenuStructureTests.swift").read_text()
        strings = json.loads((ROOT / "Sources/BrowserCore/Resources/Shell.xcstrings").read_text())

        self.assertIn('add(.print, "Print…", to: file)', host)
        self.assertIn(".newMiniWindow, .checkForUpdates, .print:", private_host)
        self.assertIn('ShellL10n.string("Could not open print panel")', host)
        error_localizations = strings["strings"]["Could not open print panel"]["localizations"]
        self.assertEqual(error_localizations["en"]["stringUnit"]["value"], "Could not open print panel")
        self.assertEqual(error_localizations["he"]["stringUnit"]["value"], "לא ניתן לפתוח את לוח ההדפסה")
        self.assertIn("runtime.printTabID(", host)
        self.assertIn("page.tab.id.uuidString, windowID: context.nativeID,", host)
        self.assertIn("profileID: store.session.selectedSpace.profileID.uuidString", host)
        self.assertIn("decltype(&shaar_tab_print) tab_print = nullptr", bridge)
        self.assertIn("SHAAR_LOAD(tab_print, tab_print)", bridge)
        required_symbols = bridge.split("return abi_minor &&", 1)[1].split(";", 1)[0]
        self.assertNotIn("tab_print", required_symbols)
        self.assertIn("[_shaarSelectedTabs[windowID] isEqualToString:tabID]", bridge)
        self.assertIn("[_shaarTabWindows[tabID] isEqualToString:windowID]", bridge)
        self.assertIn("Print…", tests)
