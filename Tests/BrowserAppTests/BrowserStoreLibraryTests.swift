// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserStoreLibraryTests {
  @Test func deleteBookmarkMustMatchTheOpenEditorRoute() {
    let store = BrowserStore()
    let profile = store.session.selectedSpace.profileID
    let editedID = UUID()
    let otherID = UUID()
    store.library.onLoad = { _, _, done in
      done(
        .success([
          "bar": [
            "id": "00000000-0000-4000-8000-000000000001", "k": "f", "t": "Bookmarks bar",
            "c": [
              ["id": editedID.uuidString, "k": "u", "t": "Edited", "u": "https://edited.test"],
              ["id": otherID.uuidString, "k": "u", "t": "Other", "u": "https://other.test"],
            ],
          ],
          "other": [
            "id": "00000000-0000-4000-8000-000000000002", "k": "f", "t": "Other bookmarks",
            "c": [],
          ],
        ]))
    }
    store.library.refresh(profile, section: .bookmarks)
    store.showBookmarkEditor(BookmarkEditorRoute(profileID: profile, mode: .edit(editedID)))
    var removed: [String] = []
    store.library.onMutation = { _, mutation, done in
      if case .bookmark(let operation) = mutation, operation["op"] as? String == "remove" {
        removed.append(operation["id"] as? String ?? "")
      }
      done(nil)
    }

    #expect(!store.deleteBookmark(otherID, profileID: profile))
    #expect(removed.isEmpty)
  }

  @Test func deleteBookmarkFromLibraryConfirmationRemainsAvailable() {
    let store = BrowserStore()
    let profile = store.session.selectedSpace.profileID
    let bookmarkID = UUID()
    store.library.onLoad = { _, _, done in
      done(
        .success([
          "bar": [
            "id": "00000000-0000-4000-8000-000000000001", "k": "f", "t": "Bookmarks bar",
            "c": [["id": bookmarkID.uuidString, "k": "u", "t": "Saved", "u": "https://saved.test"]],
          ],
          "other": [
            "id": "00000000-0000-4000-8000-000000000002", "k": "f", "t": "Other bookmarks",
            "c": [],
          ],
        ]))
    }
    store.showLibrary(.bookmarks)
    var removed: [String] = []
    store.library.onMutation = { _, mutation, done in
      if case .bookmark(let operation) = mutation, operation["op"] as? String == "remove" {
        removed.append(operation["id"] as? String ?? "")
      }
      done(nil)
    }

    #expect(store.deleteBookmark(bookmarkID, profileID: profile))
    #expect(removed == [bookmarkID.uuidString.lowercased()])
  }
}
