// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct ClosedTabStoreTests {
  @Test func onlyConfirmedCloseIsArchivedAndLateCallbackCannotDeleteRestoredTab() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = SessionFile(url: root.appending(path: "session.json"))
    let store = BrowserStore(sessionFile: file)
    store.perform(.open(URL(string: "https://example.com")!))
    try store.flushSaves()
    let tab = try #require(store.session.selectedSpace.selectedTabID)
    let before = try Data(contentsOf: file.url)
    var requests = 0
    store.onCloseTab = { _ in requests += 1 }
    store.closeTab(tab)
    #expect(requests == 1 && store.session.closedTabs.isEmpty && !store.canReopenClosedTab)
    #expect(try Data(contentsOf: file.url) == before)
    // A canceled beforeunload leaves the tab and file intact. Only this callback commits closure.
    store.nativeTabClosed(tab)
    try store.flushSaves()
    #expect(store.session.closedTabs.map(\.id) == [tab])
    #expect(try file.load() == store.session)
    let restoredStore = BrowserStore(sessionFile: file)
    #expect(restoredStore.reopenLastClosedTab())
    let restored = try #require(restoredStore.session.selectedSpace.selectedTabID)
    #expect(restored != tab && restoredStore.session.closedTabs.isEmpty)
    restoredStore.nativeTabClosed(tab)
    try restoredStore.flushSaves()
    #expect(restoredStore.session.selectedSpace.selectedTabID == restored)
    #expect(try file.load() == restoredStore.session)
  }

  @Test func staleRecoveryActionsAndPanelsCannotCrossSpacesOrReplaceConsent() throws {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://example.com/closed")!))
    let source = store.session.selectedSpaceID
    let closed = try #require(store.session.selectedSpace.selectedTabID)
    store.closeTab(closed)
    store.showRecentlyClosed()
    #expect(store.sheet?.id == BrowserSheet.recentlyClosed(spaceID: source).id)
    store.cycleSpace(by: 1)
    #expect(store.sheet == nil)
    let before = store.session
    store.perform(.reopen(space: source, tab: closed))
    #expect(store.session == before && !store.reopenLastClosedTab())
    #expect(!store.clearClosedTabs(in: source))
    store.perform(.space(source))
    store.perform(.open(URL(string: "https://example.com/media")!))
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let request = try #require(
      WebsitePermissionRequest(
        id: "reopen-media", profileID: store.session.selectedSpace.profileID,
        tabID: tab.id, pageURL: tab.url, requestingOrigin: URL(string: "https://example.com")!,
        kinds: [.camera]))
    #expect(store.requestWebsitePermission(request))
    store.showRecentlyClosed()
    let consent = store.sheet?.id
    #expect(!store.reopenLastClosedTab() && !store.clearClosedTabs(in: source))
    #expect(store.sheet?.id == consent && store.session.closedTabs.map(\.id) == [closed])
    store.resolveWebsitePermission(request.id, accepted: false)
    store.showRecentlyClosed()
    #expect(store.reopenLastClosedTab())
    #expect(store.sheet == nil && store.session.selectedSpace.selectedTab?.url.path() == "/closed")
  }

  @Test func malformedRecoveryFileIsPreservedDuringTemporarySessionChanges() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var wire = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(BrowserSession.fresh()))
        as? [String: Any])
    wire["closedTabs"] = "invalid"
    let original = try JSONSerialization.data(withJSONObject: wire)
    let file = SessionFile(url: root.appending(path: "session.json"))
    try original.write(to: file.url)
    let store = BrowserStore(sessionFile: file)
    store.perform(.open(URL(string: "https://example.com")!))
    store.closeTab(store.session.selectedSpace.selectedTabID!)
    #expect(store.reopenLastClosedTab())
    #expect(store.storageNotice != nil)
    #expect(try Data(contentsOf: file.url) == original)
  }
}
