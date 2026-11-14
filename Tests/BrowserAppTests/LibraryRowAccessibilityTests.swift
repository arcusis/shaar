// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Test func libraryFooterProgressLabelIsLocalized() {
  #expect(LibraryPanelFooterAccessibility.footerProgressLabel(language: .english) == "Updating Library…")
  #expect(LibraryPanelFooterAccessibility.footerProgressLabel(language: .hebrew) == "הספרייה מתעדכנת…")
}

@Test @MainActor func libraryPanelTitleIsAHeading() {
  #expect(LibraryPanel.titleAccessibilityTraits.contains(.isHeader))
}

@Test func bookmarkFolderStateUsesTheSelectedLanguage() {
  #expect(
    LibraryBookmarkAccessibility.folderState(collapsed: false, language: .english) == "Expanded")
  #expect(
    LibraryBookmarkAccessibility.folderState(collapsed: true, language: .english) == "Collapsed")
  #expect(LibraryBookmarkAccessibility.folderState(collapsed: false, language: .hebrew) == "מורחב")
  #expect(LibraryBookmarkAccessibility.folderState(collapsed: true, language: .hebrew) == "מכווץ")
}

@Test func historyRemovalNamesAddressWhenTitlesMatch() {
  let first = LibraryHistoryAccessibility.removeLabel(
    title: "Home", address: "https://first.test", language: .english)
  let second = LibraryHistoryAccessibility.removeLabel(
    title: "Home", address: "https://second.test", language: .english)
  #expect(first == "Remove Home at https://first.test from history")
  #expect(second == "Remove Home at https://second.test from history")
  #expect(first != second)
  #expect(
    LibraryHistoryAccessibility.removeLabel(
      title: "Home", address: "https://first.test", language: .hebrew)
      == "הסרת \u{2068}Home\u{2069} בכתובת \u{2068}https://first.test\u{2069} מההיסטוריה")
}

@Test func libraryLoadingLabelIsLocalized() {
  #expect(LibraryPanelAccessibility.loadingLabel(language: .english) == "Loading library")
  #expect(LibraryPanelAccessibility.loadingLabel(language: .hebrew) == "הספרייה בטעינה")
}
