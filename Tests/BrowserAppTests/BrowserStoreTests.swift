// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserStoreTests {
  @Test func removeSpaceProfileMembershipFocusedBenchmark() throws {
    let profile = BrowserProfile(name: "Shared")
    let spaces = (0..<2_000).map { index in
      BrowserSpace(
        profileID: profile.id, name: "Space \(index)", symbol: "square",
        tint: .lavender)
    }
    let session = try BrowserSession(
      profiles: [profile], spaces: spaces, selectedSpaceID: spaces[0].id)
    let start = ContinuousClock.now
    for _ in 0..<10 {
      var copy = session
      _ = copy.removeSpace(spaces[0].id)
    }
    print("removeSpaceProfileMembershipFocusedBenchmark: \(start.duration(to: .now))")
  }

  @Test func cyclingSpacesCancelsPendingSplitPlacement() throws {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://example.com/first")!))
    let firstSpace = store.session.selectedSpaceID
    let target = try #require(store.session.selectedSpace.selectedTabID)
    store.openSplitPane(beside: target, edge: .right)
    #expect(store.pendingSplitPlacement != nil)

    store.cycleSpace(by: 1)
    #expect(store.session.selectedSpaceID != firstSpace)
    #expect(store.pendingSplitPlacement == nil)
    store.cycleSpace(by: -1)
    store.perform(.open(URL(string: "https://example.com/later")!))
    #expect(store.session.selectedSpace.splits.isEmpty)
  }

  @Test func spaceCyclingAvailabilityRequiresAnotherSpace() throws {
    let store = BrowserStore()
    #expect(store.canCycleSpace)
    var oneSpace = BrowserSession.fresh()
    let removed = oneSpace.removeSpace(oneSpace.spaces[1].id)
    #expect(removed)
    let singleStore = BrowserStore(session: oneSpace)
    #expect(!singleStore.canCycleSpace)
    let privateSession = try BrowserSession.privateWindow(
      sourceProfileID: UUID(), firstTabID: UUID())
    #expect(!BrowserStore(session: privateSession).canCycleSpace)
  }

  @Test func nativeCloseWaitsForEngineBeforeRemovingTheTab() throws {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://example.com")!))
    let tab = try #require(store.session.selectedSpace.selectedTabID)
    let owner = store.session.selectedSpace
    var requested: UUID?
    store.onCloseTab = { requested = $0 }
    store.closeTab(tab)
    #expect(requested == tab)
    #expect(store.session.selectedSpace.selectedTabID == tab)
    store.cycleSpace(by: 1)
    let current = store.session.selectedSpaceID
    store.nativeTabClosed(tab)
    #expect(store.session.selectedSpaceID == current)
    #expect(!store.session.spaces.flatMap(\.tabs).contains { $0.id == tab })
    #expect(store.session.closedTabs.first?.spaceID == owner.id)
    #expect(store.session.closedTabs.first?.profileID == owner.profileID)
    #expect(!store.canReopenClosedTab)
  }

  @Test func lateCloseForRemovedTabDoesNotPersistAnUnchangedSession() {
    let store = BrowserStore()
    var saves = 0
    store.onSessionChanged = { saves += 1 }

    store.nativeTabClosed(UUID())

    #expect(saves == 0)
  }

  @Test func clearingTodayTabsRequestsEveryUnpinnedCloseBeforeCallbacksArrive() throws {
    let store = BrowserStore()
    let spaceID = store.session.selectedSpaceID
    store.perform(.open(URL(string: "https://example.com/pinned")!))
    let pinnedID = try #require(store.session.selectedSpace.selectedTabID)
    store.togglePin(pinnedID)
    let ordinaryIDs = (0..<4).compactMap { index in
      store.session.open(URL(string: "https://example.com/today-\(index)")!)
    }
    #expect(ordinaryIDs.count == 4)

    var requests: [UUID] = []
    store.onCloseTab = { requests.append($0) }
    store.clearTodayTabs(in: spaceID)

    #expect(Set(requests) == Set(ordinaryIDs))
    #expect(store.session.selectedSpace.tabs.count == 5)
    #expect(store.session.selectedSpace.tabs.first { $0.id == pinnedID }?.isPinned == true)

    for id in ordinaryIDs { store.nativeTabClosed(id) }
    #expect(store.session.selectedSpace.tabs.map(\.id) == [pinnedID])
    #expect(store.session.closedTabs.count == ordinaryIDs.count)
  }

  @Test func openingAndCancelingLauncherDoesNotCreateTabsOrPersistChanges() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = SessionFile(url: directory.appending(path: "session.json"))
    let store = BrowserStore(sessionFile: file)
    let before = store.session
    let savedBefore = try Data(contentsOf: file.url)
    store.showCommand()
    store.commandQuery = "example.com"
    store.dismissCommand()
    #expect(store.session == before)
    #expect(try Data(contentsOf: file.url) == savedBefore)
  }

  @Test func firstLaunchPersistsProfileIDsBeforeAnyNavigation() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = SessionFile(url: directory.appending(path: "session.json"))
    let first = BrowserStore(sessionFile: file)
    let second = BrowserStore(sessionFile: file)
    #expect(second.session == first.session)
    #expect(second.session.profiles.map(\.id) == first.session.profiles.map(\.id))
    #expect(second.session.spaces.allSatisfy { $0.tabs.isEmpty })
  }

  @Test func spaceEditsPersistWithoutReassigningTheProfile() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = SessionFile(url: directory.appending(path: "session.json"))
    let store = BrowserStore(sessionFile: file)
    let profile = store.session.selectedSpace.profileID
    let created = store.createSpace(name: "Project", sharingProfile: profile, tint: .forest)
    #expect(created)
    #expect(store.session.selectedSpace.profileID == profile)
    let id = store.session.selectedSpaceID
    let updated = store.updateSpace(id, name: "Renamed", tint: .rose)
    #expect(updated)
    #expect(store.session.selectedSpace.name == "Renamed")
    #expect(store.session.selectedSpace.profileID == profile)
    try store.flushSaves()
    #expect(try file.load() == store.session)
  }

  @Test func launcherCreatesTabInActiveSpaceAndPersistsIt() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = SessionFile(url: directory.appending(path: "session.json"))
    let store = BrowserStore(sessionFile: file)
    store.cycleSpace(by: 1)
    let profile = store.session.selectedSpace.profileID
    store.showCommand()
    store.commandQuery = "example.com"
    store.acceptCommand()
    #expect(!store.commandIsOpen)
    #expect(store.session.selectedSpace.profileID == profile)
    #expect(store.session.selectedSpace.selectedTab?.url.host() == "example.com")
    #expect(store.session.spaces[0].tabs.isEmpty)
    try store.flushSaves()
    #expect(try file.load() == store.session)
  }

  @Test func damagedSessionIsPreservedWhenUserChangesTemporarySession() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = SessionFile(url: directory.appending(path: "session.json"))
    let original = Data("{damaged".utf8)
    try original.write(to: file.url)
    let store = BrowserStore(sessionFile: file)
    #expect(store.storageNotice != nil)
    store.perform(.open(URL(string: "https://example.com")!))
    store.cycleSpace(by: 1)
    #expect(try Data(contentsOf: file.url) == original)
  }
}
