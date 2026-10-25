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

  @Test func eventsDuringReadCoalesceIntoFollowupAndWatchErrorsRemainProfileBound() async throws {
    let model = BrowserLibraryModel()
    let profile = UUID()
    var replies: [@MainActor (Result<Any, Error>) -> Void] = []
    model.onLoad = { _, _, done in replies.append(done) }
    model.refresh(profile, section: .bookmarks)
    for _ in 0..<20 { model.invalidate(profile, section: .bookmarks) }
    #expect(replies.count == 1)
    replies[0](.success(tree(title: "First")))
    try await Task.sleep(for: .milliseconds(220))
    #expect(replies.count == 2)
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
      WebsiteMediaRequest(
        id: "library-media", profileID: a, tabID: page.id,
        pageURL: page.url, requestingOrigin: page.url, kinds: [.camera]))
    #expect(store.requestWebsiteMedia(consent))
    store.showLibrary(.history)
    store.bookmarkCurrentPage()
    #expect(store.sheet?.id == "media-library-media")
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
