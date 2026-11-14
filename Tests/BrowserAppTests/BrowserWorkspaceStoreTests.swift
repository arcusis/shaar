// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserWorkspaceStoreTests {
  @Test func foreignWindowTabDropMovesTheSessionRecordAcrossStores() throws {
    let manager = try BrowserWorkspaceStore(initialSession: fixture())
    let sourceID = manager.workspace.windows[0].id
    let destinationID = try manager.newWindow(from: sourceID)
    let source = try #require(manager.stores[sourceID])
    let destination = try #require(manager.stores[destinationID])
    let sourceSpaceID = source.session.selectedSpaceID
    let destinationSpaceID = destination.session.selectedSpaceID
    let tabID = try #require(source.session.selectedSpace.selectedTabID)
    let transfer = SidebarTransfer.tab(
      sessionID: source.dragSessionID, sourceSpaceID: sourceSpaceID, tabID: tabID)

    let staleTransfer = SidebarTransfer.tab(
      sessionID: UUID(), sourceSpaceID: sourceSpaceID, tabID: tabID)
    #expect(!destination.acceptSidebarDrop(staleTransfer, into: destinationSpaceID))
    #expect(source.session.spaces.flatMap(\.tabs).contains { $0.id == tabID })

    #expect(destination.acceptSidebarDrop(transfer, into: destinationSpaceID))
    #expect(!source.session.spaces.flatMap(\.tabs).contains { $0.id == tabID })
    #expect(destination.session.spaces.flatMap(\.tabs).contains { $0.id == tabID })
    #expect(destination.session.selectedSpaceID == destinationSpaceID)
    #expect(destination.session.selectedSpace.selectedTabID == tabID)
    try manager.workspace.validate()
  }

  @Test func crossWindowTransferClearsSourceTransientTabState() throws {
    let manager = try BrowserWorkspaceStore(initialSession: fixture())
    let sourceID = manager.workspace.windows[0].id
    let destinationID = try manager.newWindow(from: sourceID)
    let source = try #require(manager.stores[sourceID])
    let destination = try #require(manager.stores[destinationID])
    let tabID = try #require(source.session.selectedSpace.selectedTabID)
    source.noteTabSleeping(tabID)
    source.tabDrag = TabDrag(tabID: tabID, fromSplitPane: false)
    source.splitTabRecency = [tabID]
    source.pendingSplitPlacement = SplitPlacement(target: tabID, edge: .right)
    let transfer = SidebarTransfer.tab(
      sessionID: source.dragSessionID, sourceSpaceID: source.session.selectedSpaceID, tabID: tabID)
    source.sidebarDrag = transfer

    #expect(source.sleepingTabIDs == [tabID])
    #expect(source.tabDrag?.tabID == tabID)
    #expect(source.splitTabRecency == [tabID])
    #expect(source.pendingSplitPlacement?.target == tabID)
    #expect(source.sidebarDrag == transfer)
    #expect(destination.acceptSidebarDrop(transfer, into: destination.session.selectedSpaceID))
    #expect(source.sleepingTabIDs.isEmpty)
    #expect(source.tabDrag == nil)
    #expect(source.splitTabRecency.isEmpty)
    #expect(source.pendingSplitPlacement == nil)
    #expect(source.sidebarDrag == nil)
  }

  @Test func roundTripTransferCannotReuseTheOriginalPermissionFrame() throws {
    let manager = try BrowserWorkspaceStore(initialSession: fixture())
    let sourceID = manager.workspace.windows[0].id
    let destinationID = try manager.newWindow(from: sourceID)
    let source = try #require(manager.stores[sourceID])
    let destination = try #require(manager.stores[destinationID])
    let tab = try #require(source.session.selectedSpace.selectedTab)
    let origin = try #require(URL(string: "https://example.com"))
    let frameID = String(repeating: "a", count: 32)
    source.rememberPermissionFrame(tab.id, frameID: frameID, origin: origin)
    let request = try #require(
      WebsitePermissionRequest(
        id: "old-window-frame", profileID: source.session.selectedSpace.profileID,
        tabID: tab.id, pageURL: tab.url, requestingOrigin: origin, kinds: [.camera],
        frameID: frameID))

    let toDestination = SidebarTransfer.tab(
      sessionID: source.dragSessionID, sourceSpaceID: source.session.selectedSpaceID,
      tabID: tab.id)
    #expect(
      destination.acceptSidebarDrop(toDestination, into: destination.session.selectedSpaceID))
    let backToSource = SidebarTransfer.tab(
      sessionID: destination.dragSessionID, sourceSpaceID: destination.session.selectedSpaceID,
      tabID: tab.id)
    #expect(source.acceptSidebarDrop(backToSource, into: source.session.selectedSpaceID))
    #expect(!source.websitePermissionIsCurrent(request))
  }

  @Test func pinnedAndPrivateWindowTransfersAreRefusedWithNotices() throws {
    let manager = try BrowserWorkspaceStore(initialSession: fixture())
    let sourceID = manager.workspace.windows[0].id
    let destinationID = try manager.newWindow(from: sourceID)
    let source = try #require(manager.stores[sourceID])
    let destination = try #require(manager.stores[destinationID])
    let pinnedTab = try #require(source.session.selectedSpace.tabs.first(where: { $0.isPinned }))
    let transfer = SidebarTransfer.tab(
      sessionID: source.dragSessionID, sourceSpaceID: source.session.selectedSpaceID,
      tabID: pinnedTab.id)

    #expect(!destination.acceptSidebarDrop(transfer, into: destination.session.selectedSpaceID))
    #expect(source.session.selectedSpace.tabs.contains { $0.id == pinnedTab.id })
    #expect(destination.sidebarNotice != nil)

    let ordinaryTab = try #require(source.session.selectedSpace.tabs.first(where: { !$0.isPinned }))
    let pinnedSectionDrop = SidebarTransfer.tab(
      sessionID: source.dragSessionID, sourceSpaceID: source.session.selectedSpaceID,
      tabID: ordinaryTab.id)
    #expect(
      !destination.acceptSidebarDrop(
        pinnedSectionDrop, into: destination.session.selectedSpaceID, pinned: true))
    #expect(destination.sidebarNotice != nil)

    let privateStore = BrowserStore(privateSession: fixture())
    #expect(
      !BrowserWorkspaceStore.canTransferTab(sourceStore: source, destinationStore: privateStore))
    #expect(
      !BrowserWorkspaceStore.canTransferTab(
        sourceStore: privateStore, destinationStore: destination))
  }

  @Test func crossWindowDropIntoPinnedFolderIsRefused() throws {
    let manager = try BrowserWorkspaceStore(initialSession: fixture())
    let sourceID = manager.workspace.windows[0].id
    let destinationID = try manager.newWindow(from: sourceID)
    let source = try #require(manager.stores[sourceID])
    let destination = try #require(manager.stores[destinationID])
    let sourceSpaceID = source.session.selectedSpaceID
    let tabID = try #require(source.session.selectedSpace.tabs.first(where: { !$0.isPinned })?.id)
    let folderID = try #require(
      destination.createFolder(
        name: "Pinned destination", in: destination.session.selectedSpaceID, section: .pinned))
    let transfer = SidebarTransfer.tab(
      sessionID: source.dragSessionID, sourceSpaceID: sourceSpaceID, tabID: tabID)

    #expect(
      !destination.acceptSidebarDrop(
        transfer, into: destination.session.selectedSpaceID, folderID: folderID))
    #expect(source.session.spaces.flatMap(\.tabs).contains { $0.id == tabID })
    #expect(!destination.session.spaces.flatMap(\.tabs).contains { $0.id == tabID })
    #expect(destination.sidebarNotice != nil)
  }

  @Test func sourceWindowCanCloseImmediatelyAfterTransfer() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = file(directory)
    let manager = try BrowserWorkspaceStore(file: file, initialSession: fixture())
    let sourceID = manager.workspace.windows[0].id
    let destinationID = try manager.newWindow(from: sourceID)
    let source = try #require(manager.stores[sourceID])
    let destination = try #require(manager.stores[destinationID])
    let sourceSpaceID = source.session.selectedSpaceID
    let tabID = try #require(source.session.selectedSpace.selectedTabID)
    let transfer = SidebarTransfer.tab(
      sessionID: source.dragSessionID, sourceSpaceID: sourceSpaceID, tabID: tabID)

    #expect(destination.acceptSidebarDrop(transfer, into: destination.session.selectedSpaceID))
    try manager.removeWindow(sourceID)
    #expect(manager.workspace.window(sourceID) == nil)
    #expect(destination.session.spaces.flatMap(\.tabs).contains { $0.id == tabID })
    try manager.flushSaves()
    #expect(try file.load() == manager.workspace)
  }

  @Test func sourceWindowLateCloseCannotRemoveTransferredTab() async throws {
    let manager = try BrowserWorkspaceStore(initialSession: fixture())
    let sourceID = manager.workspace.windows[0].id
    let destinationID = try manager.newWindow(from: sourceID)
    let source = try #require(manager.stores[sourceID])
    let destination = try #require(manager.stores[destinationID])
    let tabID = try #require(source.session.selectedSpace.selectedTabID)
    let runtime = WindowTransferRuntime()
    let events = BrowserRuntimeEvents(runtime: runtime)
    let sourceEngine = try BrowserEngine(
      events: events, windowID: sourceID.uuidString, store: source, presentsNativePanels: false)
    let destinationEngine = try BrowserEngine(
      events: events, windowID: destinationID.uuidString, store: destination,
      presentsNativePanels: false)
    defer {
      sourceEngine.suspensionTask?.cancel()
      destinationEngine.suspensionTask?.cancel()
    }
    source.library.onLoad = nil
    destination.library.onLoad = nil
    sourceEngine.reconcile()
    for _ in 0..<100 where runtime.windowID(forTabID: tabID.uuidString) == nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(runtime.windowID(forTabID: tabID.uuidString) == sourceID.uuidString)
    let transfer = SidebarTransfer.tab(
      sessionID: source.dragSessionID, sourceSpaceID: source.session.selectedSpaceID, tabID: tabID)

    #expect(destination.acceptSidebarDrop(transfer, into: destination.session.selectedSpaceID))
    #expect(runtime.discarded.contains(tabID.uuidString))
    #expect(
      !runtime.opened.contains {
        $0.tabID == tabID.uuidString && $0.windowID == destinationID.uuidString
      })
    runtime.retireWindow(sourceID.uuidString)
    events.windowClosed(sourceID.uuidString, quitting: false)
    try manager.removeWindow(sourceID)
    for _ in 0..<20 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(
      !runtime.opened.contains {
        $0.tabID == tabID.uuidString && $0.windowID == destinationID.uuidString
      })
    #expect(events.router.tabOwnerWindowID(for: tabID.uuidString) == sourceID.uuidString)
    #expect(events.router.clients.contains { $0.windowID == destinationID.uuidString })

    runtime.deliverClosed(tabID, from: sourceID.uuidString)
    #expect(events.router.tabOwnerWindowID(for: tabID.uuidString) == nil)
    #expect(events.router.clients.contains { $0.windowID == destinationID.uuidString })
    for _ in 0..<100
    where !runtime.opened.contains(where: {
      $0.tabID == tabID.uuidString && $0.windowID == destinationID.uuidString
    }) {
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(
      runtime.opened.contains {
        $0.tabID == tabID.uuidString && $0.windowID == destinationID.uuidString
      })
    #expect(destinationEngine.notice == nil)
    #expect(destinationEngine.liveTabs.contains(tabID))
    #expect(runtime.windowID(forTabID: tabID.uuidString) == destinationID.uuidString)
    runtime.deliverClosed(tabID, from: sourceID.uuidString)
    #expect(destinationEngine.liveTabs.contains(tabID))
    #expect(runtime.windowID(forTabID: tabID.uuidString) == destinationID.uuidString)
    #expect(manager.workspace.window(sourceID) == nil)
    #expect(
      manager.workspace.window(destinationID)?.session.spaces.flatMap(\.tabs).contains {
        $0.id == tabID
      } == true)
  }

  @Test func destinationTimesOutAndReportsFailedTransferredTab() async throws {
    let manager = try BrowserWorkspaceStore(initialSession: fixture())
    let sourceID = manager.workspace.windows[0].id
    let destinationID = try manager.newWindow(from: sourceID)
    let source = try #require(manager.stores[sourceID])
    let destination = try #require(manager.stores[destinationID])
    let tabID = try #require(source.session.selectedSpace.selectedTabID)
    let runtime = WindowTransferRuntime()
    let events = BrowserRuntimeEvents(runtime: runtime)
    let sourceEngine = try BrowserEngine(
      events: events, windowID: sourceID.uuidString, store: source, presentsNativePanels: false)
    let destinationEngine = try BrowserEngine(
      events: events, windowID: destinationID.uuidString, store: destination,
      presentsNativePanels: false)
    defer {
      sourceEngine.suspensionTask?.cancel()
      destinationEngine.suspensionTask?.cancel()
    }
    source.library.onLoad = nil
    destination.library.onLoad = nil
    sourceEngine.reconcile()
    for _ in 0..<100 where runtime.windowID(forTabID: tabID.uuidString) == nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    let transfer = SidebarTransfer.tab(
      sessionID: source.dragSessionID, sourceSpaceID: source.session.selectedSpaceID, tabID: tabID)

    #expect(destination.acceptSidebarDrop(transfer, into: destination.session.selectedSpaceID))
    for _ in 0..<300 where destinationEngine.notice == nil {
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(destination.session.spaces.flatMap(\.tabs).contains { $0.id == tabID })
    #expect(!destinationEngine.liveTabs.contains(tabID))
    #expect(
      !runtime.opened.contains {
        $0.tabID == tabID.uuidString && $0.windowID == destinationID.uuidString
      })
    #expect(destinationEngine.notice != nil)
  }

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

  @Test func retiredWindowStoreCannotReassignSharedSpaceProfile() throws {
    let manager = try BrowserWorkspaceStore(initialSession: fixture())
    let secondID = try manager.newWindow(from: manager.workspace.windows[0].id)
    let retiredStore = try #require(manager.stores[secondID])
    let spaceID = retiredStore.session.selectedSpaceID
    let replacementProfileID = try #require(
      retiredStore.session.profiles.first { $0.id != retiredStore.session.selectedSpace.profileID }?.id)
    try manager.removeWindow(secondID)
    let before = manager.workspace

    #expect(!retiredStore.setSpaceProfile(spaceID, to: replacementProfileID))
    #expect(manager.workspace == before)
  }
}

@MainActor
private final class WindowTransferRuntime: ARCChromiumRuntime, @unchecked Sendable {
  nonisolated(unsafe) var owners: [String: String] = [:]
  nonisolated(unsafe) var opened: [(tabID: String, windowID: String)] = []
  nonisolated(unsafe) var discarded: [String] = []

  override func isWindowOpenID(_ windowID: String) -> Bool { true }

  override func loadProfileID(_ profileID: String, completion: @escaping (Error?) -> Void) {
    completion(nil)
  }

  override func openTabID(_ tabID: String, profileID: String, windowID: String, url: String) throws
  {
    opened.append((tabID, windowID))
    owners[tabID] = windowID
  }

  override func windowID(forTabID tabID: String) -> String? { owners[tabID] }

  override func extensions(forProfileID profileID: String) -> [[String: Any]] { [] }

  override func refreshDownloads(forProfileID profileID: String) {}

  override func discardTabID(_ tabID: String) { discarded.append(tabID) }

  func retireWindow(_ windowID: String) {
    owners = owners.filter { $0.value != windowID }
  }

  func deliverClosed(_ tab: UUID, from windowID: String) {
    onTabClosed?(tab.uuidString, windowID)
  }
}
