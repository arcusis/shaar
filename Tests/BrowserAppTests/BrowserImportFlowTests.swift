// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Test func browserImportPickerCancellationDoesNotProduceAnErrorMessage() {
  #expect(LibraryImportErrorPresentation.message(for: CancellationError()) == nil)
  #expect(LibraryImportErrorPresentation.message(for: CocoaError(.userCancelled)) == nil)
  #expect(LibraryImportErrorPresentation.message(for: CocoaError(.fileReadNoPermission)) != nil)
}

@Test @MainActor func browserImportFeedsBothProfileLibraryPathsInOrder() {
  let library = BrowserLibraryModel()
  let profile = UUID()
  let folder = UUID()
  var observed: [String] = []
  var bookmarkProfile: UUID?
  var historyProfile: UUID?
  var importedSource: String?
  library.onMutation = { owner, mutation, completion in
    switch mutation {
    case .bookmarks(let operations):
      observed.append("bookmarks")
      bookmarkProfile = owner
      #expect(operations.contains { $0["u"] as? String == "https://bookmark.example.test/" })
      completion(nil)
    case .importHistory(let source, let rows):
      observed.append("history")
      historyProfile = owner
      importedSource = source.rawValue
      #expect(rows.first?["u"] as? String == "https://history.example.test/")
      #expect((rows.first?["v"] as? [Double])?.count == 2)
      completion(nil)
    case .bookmark, .deleteHistory:
      Issue.record("Unexpected non-import library mutation.")
      completion("unexpected mutation")
    }
  }
  let items = [
    BrowserImportItem(
      kind: .bookmark, source: .edge, title: "Saved", address: "https://bookmark.example.test/"),
    BrowserImportItem(
      kind: .history, source: .edge, title: "Visited", address: "https://history.example.test/",
      visitTimes: [
        Date(timeIntervalSince1970: 1_700_000_000), Date(timeIntervalSince1970: 1_700_000_001),
      ]),
  ]
  var succeeded = false
  #expect(
    library.importBrowserData(items, profile: profile, otherFolderID: folder) { succeeded = $0 })
  #expect(observed == ["bookmarks", "history"])
  #expect(bookmarkProfile == profile && historyProfile == profile)
  #expect(importedSource == "edge" && succeeded)
}
