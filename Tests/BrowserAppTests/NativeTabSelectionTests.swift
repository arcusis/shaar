// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct NativeTabSelectionTests {
  @Test func activationRevealsOwningSharedSpaceAndPersistsWithoutMovingTabs() throws {
    let profile = BrowserProfile(name: "Company")
    let folder = BrowserFolder(name: "Pinned", isCollapsed: true)
    let first = BrowserTab(url: URL(string: "https://example.com/first")!)
    let target = BrowserTab(
      url: URL(string: "https://example.com/target")!, isPinned: true, folderID: folder.id)
    let source = BrowserSpace(
      profileID: profile.id, name: "Source", symbol: "house", tint: .ocean, tabs: [first])
    let destination = BrowserSpace(
      profileID: profile.id, name: "Shared", symbol: "folder", tint: .forest, tabs: [target],
      folders: [folder])
    let session = try BrowserSession(
      profiles: [profile], spaces: [source, destination], selectedSpaceID: source.id)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = SessionFile(url: directory.appending(path: "session.json"))
    let store = BrowserStore(sessionFile: file, session: session)
    store.showCommand()
    store.commandQuery = "unfinished query"
    #expect(store.nativeTabActivated(target.id, profileID: profile.id))
    #expect(store.session.selectedSpaceID == destination.id)
    #expect(store.session.selectedSpace.selectedTabID == target.id)
    #expect(store.session.selectedSpace.folders[0].isCollapsed == false)
    #expect(store.session.spaces[0] == source)
    #expect(store.session.selectedSpace.tabs == destination.tabs)
    #expect(store.commandIsOpen && store.commandQuery == "unfinished query")
    #expect(try file.load() == store.session)
    var duplicateSaves = 0
    store.onSessionChanged = { duplicateSaves += 1 }
    #expect(store.nativeTabActivated(target.id, profileID: profile.id))
    #expect(duplicateSaves == 0)
  }

  @Test func inactiveUnknownAndWrongProfileActivationsCannotStealSelection() throws {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://example.com/alpha")!))
    let alpha = store.session.selectedSpace
    store.cycleSpace(by: 1)
    store.perform(.open(URL(string: "https://example.com/beta")!))
    let beta = store.session.selectedSpace
    store.perform(.space(alpha.id))
    store.showPageFind()
    store.updatePageFindQuery("alpha")
    let find = try #require(store.pageFind)
    let before = store.session
    #expect(!store.nativeTabActivated(beta.selectedTabID!, profileID: beta.profileID))
    #expect(!store.nativeTabActivated(alpha.selectedTabID!, profileID: beta.profileID))
    #expect(!store.nativeTabActivated(beta.selectedTabID!, profileID: alpha.profileID))
    #expect(!store.nativeTabActivated(UUID(), profileID: alpha.profileID))
    #expect(store.session == before)
    #expect(store.pageFind?.id == find.id && store.pageFind?.query == "alpha")
  }

  @Test func acceptedActivationCancelsOldFindAndDeniesStaleConsentOnce() throws {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://example.com/first")!))
    let first = try #require(store.session.selectedSpace.selectedTab)
    store.perform(.open(URL(string: "https://example.com/second")!))
    let second = try #require(store.session.selectedSpace.selectedTabID)
    let space = store.session.selectedSpaceID
    let profile = store.session.selectedSpace.profileID
    store.perform(.tab(space: space, tab: first.id))
    store.showPageFind()
    store.updatePageFindQuery("old document")
    var stopped: [UUID] = []
    store.onStopFinding = { stopped.append($0) }
    #expect(store.nativeTabActivated(second, profileID: profile))
    #expect(stopped == [first.id] && store.pageFind == nil)
    store.perform(.tab(space: space, tab: first.id))
    let consent = try #require(
      WebsitePermissionRequest(
        id: "native-selection", profileID: profile, tabID: first.id,
        pageURL: first.url, requestingOrigin: URL(string: "https://example.com")!, kinds: [.camera])
    )
    var decisions: [Bool] = []
    store.onWebsitePermissionDecision = { _, accepted in decisions.append(accepted) }
    #expect(store.requestWebsitePermission(consent))
    #expect(store.nativeTabActivated(second, profileID: profile))
    store.resolveWebsitePermission(consent.id, accepted: true)
    #expect(decisions == [false])
    #expect(store.websitePermissionRequests.isEmpty && store.sheet == nil)
    store.closeTab(second)
    let closed = store.session
    #expect(!store.nativeTabActivated(second, profileID: profile))
    #expect(store.session == closed)
  }
}
