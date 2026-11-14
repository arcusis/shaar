// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BookmarkEditorRouteTests {
  @Test func busyProgressLabelIsLocalized() {
    #expect(BookmarkEditorAccessibility.busyLabel(language: .english) == "Updating bookmarks…")
    #expect(BookmarkEditorAccessibility.busyLabel(language: .hebrew) == "מעדכן סימניות…")
  }

  @Test func bookmarkEditorTitleIsVoiceOverHeading() {
    #expect(BookmarkEditor.headingTraits.contains(.isHeader))
  }

  @Test func newBookmarkRouteRequiresItsProfileAndAnExistingFolderParent() throws {
    let store = BrowserStore()
    let profile = store.session.selectedSpace.profileID
    let folderID = UUID()
    store.library.onLoad = { _, _, done in
      done(.success(Self.tree(folderID: folderID)))
    }
    store.library.refresh(profile, section: .bookmarks)

    let rootRoute = BookmarkEditorRoute(
      profileID: profile,
      mode: .newBookmark(parent: nil, title: "Page", address: "https://example.test"))
    let folderRoute = BookmarkEditorRoute(
      profileID: profile,
      mode: .newFolder(parent: folderID))
    let invalidParentRoute = BookmarkEditorRoute(
      profileID: profile,
      mode: .newFolder(parent: UUID()))

    #expect(rootRoute.parentID == nil)
    #expect(rootRoute.matches(store))
    #expect(folderRoute.parentID == folderID)
    #expect(folderRoute.matches(store))
    #expect(!invalidParentRoute.matches(store))
    #expect(!BookmarkEditorRoute(profileID: UUID(), mode: .newFolder(parent: nil)).matches(store))
  }

  @Test func editRouteMatchesOnlyAnExistingNonpermanentBookmark() throws {
    let store = BrowserStore()
    let profile = store.session.selectedSpace.profileID
    let bookmarkID = UUID()
    let barID = UUID()
    let tree = Self.tree(bookmarkID: bookmarkID, barID: barID)
    store.library.onLoad = { _, _, done in done(.success(tree)) }
    store.library.refresh(profile, section: .bookmarks)
    let bookmark = BookmarkEditorRoute(profileID: profile, mode: .edit(bookmarkID))
    let permanentFolder = BookmarkEditorRoute(profileID: profile, mode: .edit(barID))

    #expect(bookmark.itemID == bookmarkID)
    #expect(bookmark.parentID == nil)
    #expect(bookmark.matches(store))
    #expect(!permanentFolder.matches(store))
    #expect(!BookmarkEditorRoute(profileID: profile, mode: .edit(UUID())).matches(store))
  }

  private static func tree(
    folderID: UUID = UUID(), bookmarkID: UUID = UUID(), barID: UUID = UUID()
  ) -> [String: Any] {
    [
      "bar": ["id": barID.uuidString, "t": "Bookmarks Bar", "k": "f", "c": []],
      "other": [
        "id": UUID().uuidString, "t": "Other Bookmarks", "k": "f",
        "c": [
          ["id": folderID.uuidString, "t": "Folder", "k": "f", "c": []],
          ["id": bookmarkID.uuidString, "t": "Page", "k": "u", "u": "https://example.test"],
        ],
      ],
    ]
  }
}
