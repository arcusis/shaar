// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserWorkspaceStoreTests {
  @Test func removalImpactIncludesEveryManagedWindowBeforeGlobalDeletion() throws {
    let manager = try BrowserWorkspaceStore(initialSession: fixture())
    let first = manager.workspace.windows[0].id
    let second = try manager.newWindow(from: first)
    let model = manager.stores[first]!
    let space = model.session.selectedSpaceID
    let impact = model.spaceRemovalImpact(space)
    #expect(impact.windows == 2 && impact.tabs == 3)
    #expect(impact.message.contains("all 2 windows") && impact.message.contains("3 tabs"))
    manager.stores[second]!.perform(.open(URL(string: "https://example.com/another")!))
    #expect(model.spaceRemovalImpact(space).tabs == 4)
    let profiles = manager.workspace.catalog.profiles
    #expect(model.removeSpace(space))
    #expect(manager.stores[second]!.session.spaces.allSatisfy { $0.id != space })
    #expect(manager.workspace.catalog.profiles == profiles)
  }
  private func fixture() -> BrowserSession {
    var session = BrowserSession.fresh()
    let pin = session.open(URL(string: "https://example.com/pin")!)!
    session.togglePin(pin)
    _ = session.open(URL(string: "https://example.com/ordinary")!)
    return session
  }

  private func file(_ directory: URL) -> WorkspaceFile {
    WorkspaceFile(
      url: directory.appending(path: "workspace.json"),
      legacySessionURL: directory.appending(path: "session.json"))
  }

  @Test func managedChangesPersistAllWindowsAndRestoreDistinctSelections() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = file(directory)
    let manager = try BrowserWorkspaceStore(file: file, initialSession: fixture())
    #expect(try file.load() == manager.workspace)
    let firstID = manager.workspace.windows[0].id
    let first = try #require(manager.stores[firstID])
    let secondID = try manager.newWindow(from: firstID)
    let second = try #require(manager.stores[secondID])
    second.perform(.open(URL(string: "https://example.com/second-window")!))
    let secondTab = try #require(second.session.selectedSpace.selectedTabID)
    #expect(!first.session.spaces.flatMap(\.tabs).contains { $0.id == secondTab })
    #expect(first.updateSpace(first.session.selectedSpaceID, name: "Renamed", tint: .rose))
    #expect(second.session.selectedSpace.name == "Renamed")
    #expect(second.session.selectedSpace.selectedTabID == secondTab)
    try manager.flushSaves()
    #expect(try file.load() == manager.workspace)
    let restored = try BrowserWorkspaceStore(file: file)
    #expect(restored.workspace == manager.workspace)
    #expect(restored.stores[firstID]?.session == first.session)
    #expect(restored.stores[secondID]?.session == second.session)
    #expect(restored.storageNotice == nil)
  }

  @Test func sharedPinChangesReachSiblingStoreWithoutCopyingItsOrdinaryTabs() throws {
    let manager = try BrowserWorkspaceStore(initialSession: fixture())
    let firstID = manager.workspace.windows[0].id
    let secondID = try manager.newWindow(from: firstID)
    let first = manager.stores[firstID]!
    let second = manager.stores[secondID]!
    let target = second.session.selectedSpace.tabs[0]
    second.perform(.tab(space: second.session.selectedSpaceID, tab: target.id))
    second.nativeTabChanged(
      target.id, url: URL(string: "https://example.com/current-second")!, title: "Current")
    let sourcePin = first.session.selectedSpace.tabs.first(where: \.isPinned)!
    first.closeTab(sourcePin.id)
    #expect(second.session.selectedSpace.selectedTabID == target.id)
    #expect(
      second.session.selectedSpace.selectedTab?.url.absoluteString
        == "https://example.com/current-second")
    #expect(second.session.selectedSpace.selectedTab?.isPinned == false)
    #expect(second.session.closedTabs.isEmpty)
    #expect(first.session.closedTabs.contains { $0.id == sourcePin.id })
    #expect(manager.workspace.window(secondID)?.session == second.session)
  }

  @Test func reentrantNativeMetadataCannotBeOverwrittenByAnOuterCatalogBroadcast() throws {
    let manager = try BrowserWorkspaceStore(initialSession: fixture())
    let firstID = manager.workspace.windows[0].id
    let secondID = try manager.newWindow(from: firstID)
    let first = manager.stores[firstID]!
    let second = manager.stores[secondID]!
    let pin = second.session.selectedSpace.tabs[0]
    var invoked = false
    second.onSessionChanged = {
      guard !invoked else { return }
      invoked = true
      second.nativeTabChanged(
        pin.id, url: URL(string: "https://example.com/native-metadata")!, title: "Native")
    }
    #expect(first.updateSpace(first.session.selectedSpaceID, name: "Broadcast", tint: .forest))
    #expect(invoked)
    #expect(
      second.session.selectedSpace.tabs[0].url.absoluteString
        == "https://example.com/native-metadata")
    #expect(manager.workspace.window(secondID)?.session == second.session)
    #expect(first.session.selectedSpace.name == "Broadcast")
    #expect(
      manager.workspace.catalog.spaces[0].tabs[0].url.absoluteString == "https://example.com/pin")
  }

  @Test func malformedWorkspacePreservesBothFilesAndNeverUsesStaleLegacyAsFallback() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = file(directory)
    let legacy = fixture()
    try SessionFile(url: file.legacySessionURL).save(legacy)
    let legacyBytes = try Data(contentsOf: file.legacySessionURL)
    let bad = Data("{unsupported".utf8)
    try bad.write(to: file.url)
    let fallback = BrowserSession.fresh()
    let manager = try BrowserWorkspaceStore(file: file, initialSession: fallback)
    #expect(manager.workspace.windows[0].session == fallback)
    #expect(manager.workspace.catalog.profiles != legacy.profiles)
    let firstID = manager.workspace.windows[0].id
    manager.stores[firstID]!.perform(.open(URL(string: "https://example.com/temporary")!))
    let secondID = try manager.newWindow(from: firstID)
    #expect(manager.storageNotice != nil && manager.stores[firstID]!.storageNotice != nil)
    #expect(manager.stores[secondID]!.storageNotice != nil)
    #expect(!manager.persistSnapshot())
    #expect(try Data(contentsOf: file.url) == bad)
    #expect(try Data(contentsOf: file.legacySessionURL) == legacyBytes)
  }

  @Test func writeFailureKeepsValidUnsavedIDsAndRetriesWithoutLosingEitherWindow() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let blocker = directory.appending(path: "blocked")
    try Data("not a directory".utf8).write(to: blocker)
    let file = file(blocker)
    let manager = try BrowserWorkspaceStore(file: file, initialSession: fixture())
    let firstID = manager.workspace.windows[0].id
    let secondID = try manager.newWindow(from: firstID)
    let second = manager.stores[secondID]!
    second.perform(.open(URL(string: "https://example.com/unsaved")!))
    let unsaved = manager.workspace
    #expect(manager.storageNotice != nil && second.storageNotice != nil)
    try FileManager.default.removeItem(at: blocker)
    #expect(manager.persistSnapshot())
    #expect(manager.workspace == unsaved)
    #expect(try file.load() == unsaved)
    #expect(manager.stores.values.allSatisfy { $0.storageNotice == nil })
  }

  @Test func tabMetadataSpaceAndWindowChangesAllReachTheSavedWorkspace() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = file(directory)
    let manager = try BrowserWorkspaceStore(file: file, initialSession: fixture())
    let firstID = manager.workspace.windows[0].id
    let first = try #require(manager.stores[firstID])
    let tab = try #require(first.session.selectedSpace.selectedTabID)
    let address = URL(string: "https://example.com/navigated")!

    first.nativeTabChanged(tab, url: address, title: "Navigated page")
    try manager.flushSaves()
    let savedTab = try file.load()?.window(firstID)?.session.spaces.flatMap(\.tabs)
      .first { $0.id == tab }
    #expect(savedTab?.url == address && savedTab?.title == "Navigated page")

    first.cycleSpace(by: 1)
    try manager.flushSaves()
    #expect(
      try file.load()?.window(firstID)?.session.selectedSpaceID == first.session.selectedSpaceID)

    let secondID = try manager.newWindow(from: firstID)
    try manager.focusWindow(secondID)
    try manager.setGeometry(
      WorkspaceWindowGeometry(x: 10, y: 20, width: 900, height: 700), for: secondID)
    try manager.flushSaves()
    #expect(try file.load() == manager.workspace)
  }

  @Test func damagedWorkspaceRestoresTheBackupAndKeepsSaving() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = file(directory)
    let manager = try BrowserWorkspaceStore(file: file, initialSession: fixture())
    let lastKnownGood = manager.workspace
    let firstID = lastKnownGood.windows[0].id
    manager.stores[firstID]!.perform(.open(URL(string: "https://example.com/latest")!))
    try manager.flushSaves()
    let damaged = Data("{\"windows\":".utf8)
    try damaged.write(to: file.url)

    let restored = try BrowserWorkspaceStore(file: file)
    #expect(restored.workspace == lastKnownGood)
    #expect(restored.storageNotice == nil)
    let snapshot = SnapshotFile<BrowserWorkspace>(url: file.url)
    #expect(try Data(contentsOf: snapshot.damagedURL) == damaged)

    restored.stores[firstID]!.perform(.open(URL(string: "https://example.com/after-recovery")!))
    try restored.flushSaves()
    #expect(try file.load() == restored.workspace)
    #expect(try Data(contentsOf: snapshot.backupURL) != damaged)
  }

  @Test func retiredWindowStoreCannotResurrectItsRecordAfterNativeClosure() throws {
    let manager = try BrowserWorkspaceStore(initialSession: fixture())
    let firstID = manager.workspace.windows[0].id
    let secondID = try manager.newWindow(from: firstID)
    let closed = manager.stores[secondID]!
    try manager.removeWindow(secondID)
    let before = manager.workspace
    closed.perform(.open(URL(string: "https://example.com/too-late")!))
    #expect(manager.workspace == before)
    #expect(manager.stores[secondID] == nil && closed.storageNotice != nil)
    #expect(throws: WorkspaceError.self) { try manager.focusWindow(secondID) }
    #expect(manager.workspace == before)
  }
}
