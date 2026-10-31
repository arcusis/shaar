// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserLibraryTests {
  @Test func newerReadsWinAndMalformedRepliesKeepLastGoodProfileSnapshot() throws {
    let model = BrowserLibraryModel()
    let a = UUID()
    let b = UUID()
    var replies: [@MainActor (Result<Any, Error>) -> Void] = []
    model.onLoad = { _, _, done in replies.append(done) }
    model.refresh(a, section: .bookmarks)
    model.refresh(a, section: .bookmarks)
    replies[1](.success(tree(title: "New")))
    replies[0](.success(tree(title: "Old")))
    #expect(model.bookmarks[a]?.items.contains { $0.title == "New" } == true)
    model.refresh(b, section: .bookmarks)
    replies[2](.failure(LibraryDataError.invalidBookmarks))
    #expect(
      model.notice(b, section: .bookmarks) != nil && model.notice(a, section: .bookmarks) == nil)
    let before = model.bookmarks[a]
    model.refresh(a, section: .bookmarks)
    replies[3](.success(["bar": "bad"]))
    #expect(model.bookmarks[a] == before && model.notice(a, section: .bookmarks) != nil)
  }

  @Test func writesRejectOldReadsAndRefreshExplicitlyAfterNativeAcknowledgement() throws {
    let model = BrowserLibraryModel()
    let profile = UUID()
    var reads: [@MainActor (Result<Any, Error>) -> Void] = []
    var writes: [@MainActor (String?) -> Void] = []
    model.onLoad = { _, _, done in reads.append(done) }
    model.onMutation = { _, _, done in writes.append(done) }
    model.refresh(profile, section: .bookmarks)
    let accepted = model.mutate(.bookmark(["op": "remove"]), profile: profile) { _ in }
    #expect(accepted)
    #expect(!model.mutate(.bookmark([:]), profile: profile) { _ in })
    reads[0](.success(tree(title: "Stale")))
    #expect(model.bookmarks[profile] == nil)
    writes[0](nil)
    #expect(reads.count == 2)
    reads[1](.success(tree(title: "Confirmed")))
    #expect(model.bookmarks[profile]?.items.contains { $0.title == "Confirmed" } == true)
  }

  @Test(.timeLimit(.minutes(1)))
  func eventsDuringReadCoalesceIntoFollowupAndWatchErrorsRemainProfileBound() async throws {
    let model = BrowserLibraryModel()
    let profile = UUID()
    var replies: [@MainActor (Result<Any, Error>) -> Void] = []
    let (reads, continuation) = AsyncStream<Int>.makeStream()
    defer { continuation.finish() }
    var events = reads.makeAsyncIterator()
    model.onLoad = { _, _, done in
      replies.append(done)
      continuation.yield(replies.count)
    }
    model.refresh(profile, section: .bookmarks)
    let initialRead = await events.next()
    try #require(initialRead == 1)
    for _ in 0..<20 { model.invalidate(profile, section: .bookmarks) }
    #expect(replies.count == 1)
    replies[0](.success(tree(title: "First")))
    let followupRead = await events.next()
    try #require(followupRead == 2)
    try #require(replies.count == 2)
    model.serviceFailed(profile, section: .bookmarks, message: "Updates unavailable")
    replies[1](.success(tree(title: "Updated")))
    #expect(model.notice(profile, section: .bookmarks) == "Updates unavailable")
    #expect(model.notice(UUID(), section: .bookmarks) == nil)
  }

  @Test func historyLoadMoreUsesLargerBoundAndNeverDuplicatesRows() throws {
    let model = BrowserLibraryModel()
    let profile = UUID()
    var requested: [Int] = []
    model.onLoad = { key, limit, done in
      #expect(key.profileID == profile && key.section == .history)
      requested.append(limit)
      done(
        .success(
          (0..<limit).map { index in
            [
              "u": "https://example.com/\(index)", "t": "Page \(index)", "n": 1,
              "v": [1000 + index],
            ] as [String: Any]
          }))
    }
    model.refresh(profile, section: .history)
    #expect(model.hasMoreHistory(profile))
    model.loadMoreHistory(profile)
    #expect(requested == [500, 1000] && model.history[profile]?.count == 1000)
    model.onLoad = { _, _, done in
      done(
        .success([
          ["u": "https://example.com", "t": "Duplicate", "n": 1, "v": [1000]],
          ["u": "https://example.com", "t": "Duplicate", "n": 1, "v": [2000]],
        ]))
    }
    model.refresh(profile, section: .history)
    #expect(
      model.history[profile]?.count == 1000 && model.notice(profile, section: .history) != nil)
  }

  @Test func staleLibraryActionsCannotCrossProfilesOrReplaceConsent() throws {
    let store = BrowserStore()
    let a = store.session.selectedSpace.profileID
    let id = UUID()
    store.library.onLoad = { _, _, done in done(.success(tree(title: "Alpha", id: id))) }
    store.library.refresh(a, section: .bookmarks)
    store.showLibrary(.bookmarks)
    store.cycleSpace(by: 1)
    #expect(store.sheet == nil)
    let before = store.session
    store.perform(.bookmark(profile: a, id: id))
    #expect(store.session == before)
    #expect(!store.moveBookmark(id, profileID: a, to: UUID()))
    #expect(!store.deleteBookmark(id, profileID: a))
    store.perform(.space(store.session.spaces[0].id))
    store.perform(.open(URL(string: "https://example.com")!))
    let page = store.session.selectedSpace.selectedTab!
    let consent = try #require(
      WebsitePermissionRequest(
        id: "library-media", profileID: a, tabID: page.id,
        pageURL: page.url, requestingOrigin: page.url, kinds: [.camera]))
    #expect(store.requestWebsitePermission(consent))
    store.showLibrary(.history)
    store.bookmarkCurrentPage()
    #expect(store.sheet?.id == "permission-library-media")
    #expect(!store.deleteBookmark(id, profileID: a) && !store.openBookmark(id, profileID: a))
  }

  @Test func sharedSpacesUseSameLibraryButOpenIntoTheirCurrentSpace() throws {
    let store = BrowserStore()
    let id = UUID()
    let profile = store.session.selectedSpace.profileID
    store.library.onLoad = { _, _, done in done(.success(tree(title: "Shared", id: id))) }
    store.library.refresh(profile, section: .bookmarks)
    #expect(store.createSpace(name: "Shared", sharingProfile: profile, tint: .ocean))
    let space = store.session.selectedSpaceID
    #expect(store.openBookmark(id, profileID: profile))
    #expect(
      store.session.selectedSpaceID == space
        && store.session.selectedSpace.selectedTab?.url.host() == "example.com")
    #expect(store.session.spaces[0].tabs.isEmpty)
  }

  @Test func bookmarkSaveUsesStableIDAndLateSuccessCannotDismissAnotherProfileSheet() throws {
    let store = BrowserStore()
    let profile = store.session.selectedSpace.profileID
    store.library.onLoad = { _, _, done in done(.success(tree(title: "Existing"))) }
    store.library.refresh(profile, section: .bookmarks)
    var callbacks: [@MainActor (String?) -> Void] = []
    var operations: [[String: Any]] = []
    store.library.onMutation = { owner, mutation, done in
      #expect(owner == profile)
      if case .bookmark(let operation) = mutation { operations.append(operation) }
      callbacks.append(done)
    }
    let route = BookmarkEditorRoute(
      profileID: profile,
      mode: .newBookmark(parent: nil, title: "New", address: "https://new.example.com"))
    store.showBookmarkEditor(route)
    #expect(!store.saveBookmark(route, title: "Bad", address: "javascript:alert(1)", parentID: nil))
    #expect(
      store.saveBookmark(route, title: "New", address: "https://new.example.com", parentID: nil))
    #expect(operations.first?["id"] as? String == route.id.uuidString.lowercased())
    store.cycleSpace(by: 1)
    store.showRecentlyClosed()
    let other = store.sheet?.id
    callbacks[0](nil)
    #expect(store.sheet?.id == other)
    #expect(
      !store.saveBookmark(route, title: "Stale", address: "https://new.example.com", parentID: nil))
  }
}

extension BrowserLibraryTests {
  @Test func bookmarkingABookmarkedPageEditsTheExistingBookmark() {
    let store = BrowserStore()
    let profile = store.session.selectedSpace.profileID
    let id = UUID()
    store.library.onLoad = { _, _, done in done(.success(tree(title: "Example", id: id))) }
    store.library.refresh(profile, section: .bookmarks)
    var operations: [[String: Any]] = []
    store.library.onMutation = { _, mutation, done in
      if case .bookmark(let operation) = mutation { operations.append(operation) }
      done(nil)
    }
    store.perform(.open(URL(string: "https://example.com")!))
    store.bookmarkCurrentPage()
    guard case .bookmarkEditor(let route) = store.sheet else {
      Issue.record("Expected the bookmark editor")
      return
    }
    #expect(route.itemID == id)
    #expect(!store.saveBookmark(route, title: "Renamed", address: "not a url", parentID: nil))
    #expect(
      store.saveBookmark(
        route, title: " Renamed ", address: "https://example.com/new", parentID: nil))
    #expect(operations.first?["op"] as? String == "update")
    #expect(operations.first?["t"] as? String == "Renamed")
    #expect(operations.first?["u"] as? String == "https://example.com/new")
    #expect(store.sheet == nil)
  }

  @Test func deletingTheEditedBookmarkClosesItsEditor() throws {
    let store = BrowserStore()
    let profile = store.session.selectedSpace.profileID
    let id = UUID()
    store.library.onLoad = { _, _, done in done(.success(tree(title: "Example", id: id))) }
    store.library.refresh(profile, section: .bookmarks)
    var removed: [String] = []
    store.library.onMutation = { _, mutation, done in
      if case .bookmark(let operation) = mutation, operation["op"] as? String == "remove" {
        removed.append(operation["id"] as? String ?? "")
      }
      done(nil)
    }
    store.showBookmarkEditor(BookmarkEditorRoute(profileID: profile, mode: .edit(id)))
    #expect(store.deleteBookmark(id, profileID: profile))
    #expect(removed == [id.uuidString.lowercased()])
    #expect(store.sheet == nil)
    let bar = try #require(store.library.bookmarks[profile]?.barID)
    #expect(!store.deleteBookmark(bar, profileID: profile))
  }

  @Test func bookmarksMoveOnlyIntoFoldersAndPermanentFoldersStayPut() throws {
    let store = BrowserStore()
    let profile = store.session.selectedSpace.profileID
    let id = UUID()
    store.library.onLoad = { _, _, done in done(.success(tree(title: "Example", id: id))) }
    store.library.refresh(profile, section: .bookmarks)
    var moves: [String] = []
    store.library.onMutation = { _, mutation, done in
      if case .bookmark(let operation) = mutation {
        moves.append(operation["parent"] as? String ?? "")
      }
      done(nil)
    }
    let other = try #require(store.library.bookmarks[profile]?.otherID)
    #expect(!store.moveBookmark(id, profileID: profile, to: id))
    #expect(!store.moveBookmark(other, profileID: profile, to: other))
    #expect(store.moveBookmark(id, profileID: profile, to: other))
    #expect(moves == [other.uuidString.lowercased()])
  }

  @Test func historyEntriesOpenInTheCurrentSpaceAndCanBeDeleted() {
    let store = BrowserStore()
    let profile = store.session.selectedSpace.profileID
    let address = "https://history.example/page"
    store.library.onLoad = { _, _, done in
      done(.success([["u": address, "t": "Visited", "n": 2, "v": [1000]] as [String: Any]]))
    }
    var deleted: [String] = []
    store.library.onMutation = { _, mutation, done in
      if case .deleteHistory(let value) = mutation { deleted.append(value) }
      done(nil)
    }
    store.showLibrary(.history)
    #expect(!store.deleteHistoryEntry("https://unknown.example/", profileID: profile))
    #expect(store.deleteHistoryEntry(address, profileID: profile))
    #expect(deleted == [address])
    #expect(!store.openHistoryEntry(address, profileID: UUID()))
    #expect(store.openHistoryEntry(address, profileID: profile))
    #expect(store.sheet == nil)
    #expect(store.session.selectedSpace.selectedTab?.url.absoluteString == address)
  }
}

private func tree(title: String, id: UUID = UUID()) -> [String: Any] {
  [
    "bar": [
      "id": "00000000-0000-4000-8000-000000000001", "k": "f", "t": "Bookmarks bar",
      "c": [
        ["id": id.uuidString, "k": "u", "t": title, "u": "https://example.com"]
      ],
    ],
    "other": [
      "id": "00000000-0000-4000-8000-000000000002", "k": "f", "t": "Other bookmarks", "c": [],
    ],
  ]
}
