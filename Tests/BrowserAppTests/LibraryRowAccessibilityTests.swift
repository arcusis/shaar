// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Testing

@testable import ArcusisBrowser

@Test func bookmarkFolderStateUsesTheSelectedLanguage() {
  #expect(
    LibraryBookmarkAccessibility.folderState(collapsed: false, language: .english) == "Expanded")
  #expect(
    LibraryBookmarkAccessibility.folderState(collapsed: true, language: .english) == "Collapsed")
  #expect(LibraryBookmarkAccessibility.folderState(collapsed: false, language: .hebrew) == "מורחב")
  #expect(LibraryBookmarkAccessibility.folderState(collapsed: true, language: .hebrew) == "מכווץ")
}
