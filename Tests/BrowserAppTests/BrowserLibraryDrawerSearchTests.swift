// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import Testing

@testable import BrowserCore
@testable import ArcusisBrowser

@Test func libraryFilterSnapshotCachesCollapsedBookmarkAncestry() {
  let profileID = UUID()
  let collapsedFolderID = UUID()
  let childFolderID = UUID()
  let visibleSiblingID = UUID()
  let items = [
    BrowserBookmark(
      id: collapsedFolderID, profileID: profileID, parentID: nil, title: "Collapsed",
      address: nil, depth: 0, path: "Collapsed", isPermanent: false),
    BrowserBookmark(
      id: childFolderID, profileID: profileID, parentID: collapsedFolderID, title: "Child folder",
      address: nil, depth: 1, path: "Collapsed/Child folder", isPermanent: false),
    BrowserBookmark(
      id: UUID(), profileID: profileID, parentID: childFolderID, title: "Hidden page",
      address: "https://example.com/hidden", depth: 2, path: "Collapsed/Child folder/Hidden page",
      isPermanent: false),
    BrowserBookmark(
      id: visibleSiblingID, profileID: profileID, parentID: nil, title: "Visible page",
      address: "https://example.com/visible", depth: 0, path: "Visible page", isPermanent: false),
  ]

  var ancestryEvaluations = 0
  let snapshot = LibraryPanelFilteredRows {
    ancestryEvaluations += 1
    return LibraryPanelSearch.bookmarkRows(
      items: items, collapsed: [collapsedFolderID], query: "")
  }
  let rowsUsedByList = snapshot.rows
  let emptyState = snapshot.isEmpty

  #expect(rowsUsedByList.map(\.id) == [collapsedFolderID, visibleSiblingID])
  #expect(!emptyState)
  #expect(ancestryEvaluations == 1)
}

@Test @MainActor func spacesLibraryDrawerProvidesEditableSearchField() {
  let store = BrowserStore()
  #expect(store.showLibraryDrawer(.spaces))
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
    styleMask: [], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  defer { window.close() }
  let host = NSHostingView(rootView: BrowserLibraryDrawer(store: store))
  window.contentView = host
  host.frame = window.contentView!.bounds
  host.layoutSubtreeIfNeeded()
  window.displayIfNeeded()

  func editableFields(in view: NSView) -> [NSTextField] {
    let current = (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []
    return current + view.subviews.flatMap(editableFields)
  }

  let fields = editableFields(in: host)
  #expect(fields.count == 1)
  #expect(fields.first?.placeholderString == PanelsL10n.string("Search Spaces…"))
}
