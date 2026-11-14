// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserLibraryModelTests {
  @Test func failedBookmarkImportDoesNotContinueToHistory() {
    let model = BrowserLibraryModel()
    var bookmarkMutations = 0
    var historyMutations = 0
    var result: Bool?
    model.onMutation = { _, mutation, completion in
      switch mutation {
      case .bookmark, .bookmarks: bookmarkMutations += 1
      case .deleteHistory, .importHistory: historyMutations += 1
      }
      completion("Bookmarks could not be imported")
    }
    let items = [
      BrowserImportItem(
        kind: .bookmark, source: .edge, title: "Saved", address: "https://saved.example"),
      BrowserImportItem(
        kind: .history, source: .edge, title: "Visited", address: "https://visited.example",
        visitTimes: [Date()]),
    ]

    let accepted = model.importBrowserData(items, profile: UUID(), otherFolderID: UUID()) {
      result = $0
    }

    #expect(accepted)
    #expect(result == false)
    #expect(bookmarkMutations == 1)
    #expect(historyMutations == 0)
  }
}
