import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct PageFindTests {
  private func store() -> BrowserStore {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://example.com/page")!))
    return store
  }

  @Test func findIsNotAvailableWithoutATabOrOverAModal() {
    let store = BrowserStore()
    store.showPageFind()
    #expect(store.pageFind == nil)
    store.perform(.open(URL(string: "https://example.com")!))
    store.spaceEditor = .create
    store.showPageFind()
    #expect(store.pageFind == nil)
  }

  @Test func latestQueryOwnsResultsAndPartialUpdatesDoNotInventCounts() throws {
    let store = store()
    var searches: [(PageFindState, Bool)] = []
    store.onFindRequest = { request, forward in
      searches.append((request, forward))
      return true
    }
    store.showPageFind()
    store.updatePageFindQuery("old query")
    let old = try #require(store.pageFind)
    store.updatePageFindQuery("current query")
    let current = try #require(store.pageFind)
    store.receiveFindResult(
      tabID: old.tabID, requestID: old.requestID, count: 8, active: 1, final: true)
    store.receiveFindResult(
      tabID: UUID(), requestID: current.requestID, count: 9, active: 1, final: true)
    #expect(store.pageFind?.matchCount == nil)
    #expect(store.pageFind?.status == "Searching…")
    store.movePageFind(forward: false)
    #expect(searches.count == 2)
    store.receiveFindResult(
      tabID: current.tabID, requestID: current.requestID, count: 3, active: -1, final: false)
    #expect(store.pageFind?.status == "3 matches")
    #expect(store.pageFind?.canMove == false)
    store.receiveFindResult(
      tabID: current.tabID, requestID: current.requestID, count: -1, active: 1, final: true)
    #expect(store.pageFind?.status == "1 of 3")
    #expect(store.pageFind?.canMove == true)
    store.movePageFind(forward: false)
    #expect(searches.count == 3)
    #expect(searches.last?.1 == false)
    #expect(searches.last?.0.requestID != current.requestID)
    store.updatePageFindQuery("missing")
    let missing = try #require(store.pageFind)
    store.receiveFindResult(
      tabID: missing.tabID, requestID: missing.requestID, count: 0, active: 0, final: true)
    #expect(store.pageFind?.status == "No matches")
    #expect(store.pageFind?.canMove == false)
  }

  @Test func switchingContextsClearsQueryEvenWhenProfilesAreShared() throws {
    let store = store()
    let original = store.session.selectedSpace
    var stopped: [UUID] = []
    store.onStopFinding = { stopped.append($0) }
    store.showPageFind()
    store.updatePageFindQuery("account-specific query")
    let first = try #require(store.pageFind)
    store.cycleSpace(by: 1)
    #expect(store.pageFind == nil)
    #expect(stopped == [first.tabID])
    store.receiveFindResult(
      tabID: first.tabID, requestID: first.requestID, count: 2, active: 1, final: true)
    #expect(store.pageFind == nil)
    store.perform(.space(original.id))
    store.showPageFind()
    #expect(store.pageFind?.query == "")
    store.updatePageFindQuery("private text")
    #expect(store.createSpace(name: "Shared", sharingProfile: original.profileID, tint: .ocean))
    #expect(store.session.selectedSpace.profileID == original.profileID)
    #expect(store.pageFind == nil)
    #expect(stopped == [first.tabID, first.tabID])
  }

  @Test func navigationClosureLauncherAndConsentStopTheOwningSearch() throws {
    let store = store()
    let tab = try #require(store.session.selectedSpace.selectedTab)
    var stopped = 0
    store.onStopFinding = { id in
      #expect(id == tab.id)
      stopped += 1
    }
    store.showPageFind()
    store.nativeTabChanged(tab.id, url: tab.url, title: "New title")
    #expect(store.pageFind != nil)
    store.nativeTabChanged(tab.id, url: URL(string: "https://example.com/other")!, title: "Other")
    #expect(store.pageFind == nil)
    store.showPageFind()
    store.showCommand()
    #expect(store.pageFind == nil)
    store.showPageFind()
    #expect(!store.commandIsOpen)
    let request = try #require(
      WebsiteMediaRequest(
        id: "p1", profileID: store.session.selectedSpace.profileID, tabID: tab.id,
        pageURL: store.session.selectedSpace.selectedTab!.url,
        requestingOrigin: URL(string: "https://example.com")!, kinds: [.microphone]))
    #expect(store.requestWebsiteMedia(request))
    #expect(store.pageFind == nil)
    store.showPageFind()
    #expect(store.pageFind == nil)
    store.resolveWebsiteMedia(request.id, accepted: false)
    store.sheetDidDismiss()
    store.showPageFind()
    store.nativeTabClosed(tab.id)
    #expect(store.pageFind == nil)
    #expect(stopped == 4)
  }

  @Test func clearingAndDismissingInvalidatesRepliesWithoutSavingSearchText() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = SessionFile(url: directory.appending(path: "session.json"))
    let store = BrowserStore(sessionFile: file)
    store.perform(.open(URL(string: "https://example.com")!))
    let before = try Data(contentsOf: file.url)
    store.showPageFind()
    store.updatePageFindQuery("sensitive query")
    let current = try #require(store.pageFind)
    var stopped = 0
    store.onStopFinding = { _ in stopped += 1 }
    store.updatePageFindQuery("")
    store.receiveFindResult(
      tabID: current.tabID, requestID: current.requestID, count: 3, active: 1, final: true)
    #expect(store.pageFind?.status == "")
    #expect(store.pageFind?.matchCount == nil)
    #expect(stopped == 1)
    store.dismissPageFind()
    store.dismissPageFind()
    #expect(stopped == 2)
    #expect(try Data(contentsOf: file.url) == before)
    #expect(BrowserStore(sessionFile: file).pageFind == nil)
  }

  @Test func repeatedFindRefocusesWithoutChangingTheQueryAndUnavailablePagesStayExplicit() throws {
    let store = store()
    store.onFindRequest = { _, _ in false }
    store.showPageFind()
    store.updatePageFindQuery("find me")
    let current = try #require(store.pageFind)
    #expect(current.status == "Page unavailable")
    #expect(!current.canMove)
    store.showPageFind()
    #expect(store.pageFind?.id == current.id)
    #expect(store.pageFind?.query == current.query)
    #expect(store.pageFind?.focusRequest != current.focusRequest)
  }
}
