// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct PinnedTabRecoveryTests {
  @Test func unsolicitedNativeCloseCannotArchiveSavedPin() throws {
    let (store, tab) = try makeStore()
    let before = store.session
    store.nativeTabClosed(tab.id)
    #expect(store.session == before)
    #expect(store.session.closedTabs.isEmpty)
  }

  @Test func userCloseStillWaitsForConfirmationAndCanReopenPin() throws {
    let (store, tab) = try makeStore()
    var requested: [UUID] = []
    store.onCloseTab = { requested.append($0) }
    store.closeTab(tab.id)
    #expect(requested == [tab.id])
    #expect(store.session.selectedPage?.tab.id == tab.id)
    #expect(store.session.closedTabs.isEmpty)
    store.nativeTabClosed(tab.id)
    #expect(store.session.closedTabs.map(\.id) == [tab.id])
    #expect(store.reopenLastClosedTab())
    let recovered = try #require(store.session.selectedPage?.tab)
    #expect(recovered.isPinned && recovered.url == tab.url && recovered.id != tab.id)
    store.nativeTabClosed(tab.id)
    #expect(store.session.selectedPage?.tab == recovered)
  }

  @Test func repeatedPendingCloseRequestsCoalesceAndCanRetryAfterNavigation() throws {
    let (store, tab) = try makeStore()
    var requested: [UUID] = []
    store.onCloseTab = { requested.append($0) }

    store.closeTab(tab.id)
    store.closeTab(tab.id)
    #expect(requested == [tab.id])

    store.nativeDocumentCommitted(tab.id, profileID: store.session.selectedSpace.profileID)
    store.closeTab(tab.id)
    #expect(requested == [tab.id, tab.id])
  }

  @Test func rendererExitReportedByCloseArchivesThePin() async throws {
    let (store, tab) = try makeStore()
    let runtime = PinRecoveryRuntime()
    runtime.reportRendererGoneOnClose = true
    runtime.closeProfileID = store.session.selectedSpace.profileID.uuidString
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: runtime), store: store, presentsNativePanels: false)
    defer { engine.suspensionTask?.cancel() }
    store.library.onLoad = nil
    engine.reconcile()
    for _ in 0..<100 where runtime.opened.isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(engine.liveTabs.contains(tab.id))
    #expect(runtime.windowID(forTabID: tab.id.uuidString) == engine.windowID)
    #expect(
      engine.events.router.client(
        forTab: tab.id.uuidString, nativeWindowID: engine.windowID) != nil)
    store.closeTab(tab.id)
    #expect(store.session.closedTabs.map(\.id) == [tab.id])
    #expect(store.rendererFailures[tab.id] == nil)
    #expect(!engine.liveTabs.contains(tab.id))
  }

  @Test func rendererFailureRevokesPendingCloseIntent() throws {
    let (store, tab) = try makeStore()
    store.onCloseTab = { _ in }
    store.closeTab(tab.id)
    store.nativeRendererGone(
      tab.id, profileID: store.session.selectedSpace.profileID, status: "renderer_gone", exitCode: 0
    )
    store.nativeTabClosed(tab.id)
    #expect(store.session.selectedPage?.tab == tab)
    #expect(store.session.closedTabs.isEmpty)
  }

  @Test func unsolicitedClosePreservesSharedPinsAndWorkspaceSnapshot() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = WorkspaceFile(
      url: directory.appending(path: "workspace.json"),
      legacySessionURL: directory.appending(path: "session.json"))
    let (initial, _) = try makeStore()
    let manager = try BrowserWorkspaceStore(file: file, initialSession: initial.session)
    let firstID = try #require(manager.workspace.windows.first?.id)
    _ = try manager.newWindow(from: firstID)
    let before = manager.workspace
    let store = try #require(manager.stores[firstID])
    let pin = try #require(store.session.selectedPage?.tab)
    store.nativeTabClosed(pin.id)
    manager.persistSnapshot()
    try manager.flushSaves()
    #expect(manager.workspace == before)
    #expect(try file.load() == before)
    #expect(try BrowserWorkspaceStore(file: file).workspace == before)
  }

  @Test(arguments: [false, true])
  func failedStartupOpenKeepsPinAndReloadRetries(closeDuringOpen: Bool) async throws {
    let (store, tab) = try makeStore()
    let runtime = PinRecoveryRuntime()
    runtime.failOpen = true
    runtime.closeDuringOpen = closeDuringOpen
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: runtime), store: store, presentsNativePanels: false)
    defer { engine.suspensionTask?.cancel() }
    store.library.onLoad = nil
    engine.reconcile()
    for _ in 0..<100 where runtime.opened.isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(runtime.opened == [tab.id.uuidString])
    #expect(store.session.selectedPage?.tab == tab)
    #expect(store.session.closedTabs.isEmpty)
    #expect(!engine.liveTabs.contains(tab.id))
    engine.reconcile()
    #expect(runtime.opened.count == 1)
    runtime.failOpen = false
    #expect(store.reloadCurrentPage())
    #expect(runtime.opened == [tab.id.uuidString, tab.id.uuidString])
    #expect(engine.liveTabs.contains(tab.id))
  }

  @Test func rendererGoneKeepsLivePinAndReloadUsesExistingDocument() throws {
    let (store, tab) = try makeStore()
    let runtime = PinRecoveryRuntime()
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: runtime), store: store, presentsNativePanels: false)
    defer { engine.suspensionTask?.cancel() }
    engine.liveTabs.insert(tab.id)
    runtime.owners[tab.id.uuidString] = engine.windowID
    #expect(engine.events.router.bindTab(tab.id.uuidString, windowID: engine.windowID))
    runtime.onRendererGone?(
      tab.id.uuidString, store.session.selectedSpace.profileID.uuidString, "renderer_gone", 0)
    let failure = try #require(store.rendererFailures[tab.id])
    #expect(store.session.selectedPage?.tab == tab && store.session.closedTabs.isEmpty)
    #expect(store.reloadFailedPage(failure.id))
    #expect(runtime.reloaded == [tab.id.uuidString])
    #expect(runtime.opened.isEmpty)
  }

  @Test func rejectedReloadOfLivePinRecreatesTheDocument() async throws {
    let (store, tab) = try makeStore()
    let runtime = PinRecoveryRuntime()
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: runtime), store: store, presentsNativePanels: false)
    defer { engine.suspensionTask?.cancel() }
    store.library.onLoad = nil
    engine.reconcile()
    for _ in 0..<100 where runtime.opened.isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }
    runtime.rejectReload = true
    runtime.onRendererGone?(
      tab.id.uuidString, store.session.selectedSpace.profileID.uuidString, "renderer_gone", 0)
    let failure = try #require(store.rendererFailures[tab.id])
    #expect(store.reloadFailedPage(failure.id))
    #expect(runtime.reloaded == [tab.id.uuidString])
    #expect(!engine.liveTabs.contains(tab.id))
    for _ in 0..<100 where runtime.opened.count < 2 {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(runtime.opened == [tab.id.uuidString, tab.id.uuidString])
    #expect(engine.liveTabs.contains(tab.id))
    #expect(store.session.selectedPage?.tab == tab)
    #expect(store.session.closedTabs.isEmpty)
  }

  @Test func rejectedReloadWithoutRendererFailureLeavesTheLiveTab() throws {
    let (store, tab) = try makeStore()
    let runtime = PinRecoveryRuntime()
    runtime.rejectReload = true
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: runtime), store: store, presentsNativePanels: false)
    defer { engine.suspensionTask?.cancel() }
    engine.liveTabs.insert(tab.id)
    runtime.owners[tab.id.uuidString] = engine.windowID
    #expect(engine.events.router.bindTab(tab.id.uuidString, windowID: engine.windowID))
    #expect(!store.reloadCurrentPage())
    #expect(runtime.reloaded == [tab.id.uuidString])
    #expect(runtime.opened.isEmpty)
    #expect(engine.liveTabs.contains(tab.id))
  }

  @Test func reloadNeverReopensTabInRetiredNativeWindow() async throws {
    let (store, tab) = try makeStore()
    let runtime = PinRecoveryRuntime()
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: runtime), store: store, presentsNativePanels: false)
    defer { engine.suspensionTask?.cancel() }
    store.library.onLoad = nil
    engine.reconcile()
    for _ in 0..<100 where runtime.opened.isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }
    runtime.destroy(tab.id)
    let failure = try #require(store.rendererFailures[tab.id])
    runtime.windowOpen = false
    var lost = 0
    engine.onNativeWindowLost = { lost += 1 }

    #expect(!store.reloadFailedPage(failure.id))
    #expect(lost == 1)
    #expect(runtime.opened == [tab.id.uuidString])
    #expect(store.session.selectedPage?.tab == tab)
  }

  @Test func notFoundDuringOpenDoesNotRehomeLiveWindow() async throws {
    let (store, tab) = try makeStore()
    let runtime = PinRecoveryRuntime()
    runtime.openReturnsNotFound = true
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: runtime), store: store, presentsNativePanels: false)
    defer { engine.suspensionTask?.cancel() }
    store.library.onLoad = nil
    var lost = 0
    engine.onNativeWindowLost = { lost += 1 }
    engine.reconcile()
    for _ in 0..<100 where runtime.opened.isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(engine.notice != nil)
    #expect(!engine.liveTabs.contains(tab.id))
    #expect(lost == 0)
    #expect(runtime.opened == [tab.id.uuidString])
  }

  @Test func destroyedNativePinIsRetainedOnDiskAndReloadRecreatesIt() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = SessionFile(url: directory.appending(path: "session.json"))
    let (initial, tab) = try makeStore()
    try file.save(initial.session)
    let store = BrowserStore(sessionFile: file)
    let runtime = PinRecoveryRuntime()
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: runtime), store: store, presentsNativePanels: false)
    defer { engine.suspensionTask?.cancel() }
    store.library.onLoad = nil
    engine.reconcile()
    for _ in 0..<100 where runtime.opened.isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(runtime.opened == [tab.id.uuidString])
    runtime.destroy(tab.id)
    #expect(store.session.selectedPage?.tab == tab)
    #expect(!engine.liveTabs.contains(tab.id))
    #expect(store.session.closedTabs.isEmpty)
    try store.flushSaves()
    #expect(try file.load()?.selectedPage?.tab == tab)
    let failure = try #require(store.rendererFailures[tab.id])
    engine.reconcile()
    #expect(runtime.opened.count == 1)
    #expect(store.reloadFailedPage(failure.id))
    #expect(runtime.opened == [tab.id.uuidString, tab.id.uuidString])
    #expect(engine.liveTabs.contains(tab.id))
    runtime.onDocumentCommitted?(
      tab.id.uuidString, store.session.selectedSpace.profileID.uuidString)
    #expect(store.rendererFailures[tab.id] == nil)
    store.closeTab(tab.id)
    #expect(store.session.closedTabs.map(\.id) == [tab.id])
  }

  private func makeStore() throws -> (BrowserStore, BrowserTab) {
    let profile = BrowserProfile(name: "Recovery")
    let tab = BrowserTab(url: URL(string: "https://example.com/pin")!, isPinned: true)
    let space = BrowserSpace(
      profileID: profile.id, name: "Test", symbol: "globe", tint: .ocean,
      tabs: [tab], selectedTabID: tab.id)
    return (
      BrowserStore(
        session: try BrowserSession(
          profiles: [profile], spaces: [space], selectedSpaceID: space.id)), tab
    )
  }
}

private final class PinRecoveryRuntime: ARCChromiumRuntime, @unchecked Sendable {
  nonisolated(unsafe) var opened: [String] = []
  nonisolated(unsafe) var reloaded: [String] = []
  nonisolated(unsafe) var owners: [String: String] = [:]
  nonisolated(unsafe) var failOpen = false
  nonisolated(unsafe) var closeDuringOpen = false
  nonisolated(unsafe) var windowOpen = true
  nonisolated(unsafe) var openReturnsNotFound = false
  nonisolated(unsafe) var rejectReload = false
  nonisolated(unsafe) var reportRendererGoneOnClose = false
  nonisolated(unsafe) var closeProfileID = ""

  override func isWindowOpenID(_ windowID: String) -> Bool { windowOpen }

  override func loadProfileID(_ profileID: String, completion: @escaping (Error?) -> Void) {
    completion(nil)
  }

  override func openTabID(_ tabID: String, profileID: String, windowID: String, url: String) throws
  {
    opened.append(tabID)
    if openReturnsNotFound {
      throw NSError(domain: "org.arcusis.shaar.engine", code: 4)
    }
    if failOpen {
      if closeDuringOpen { onTabClosed?(tabID, windowID) }
      throw CocoaError(.coderInvalidValue)
    }
    owners[tabID] = windowID
  }

  override func windowID(forTabID tabID: String) -> String? { owners[tabID] }

  override func extensions(forProfileID profileID: String) -> [[String: Any]] { [] }

  override func refreshDownloads(forProfileID profileID: String) {}

  override func reloadTabID(_ tabID: String, profileID: String, mode: ARCPageReloadMode) -> Bool {
    reloaded.append(tabID)
    return !rejectReload
  }

  override func closeTabID(_ tabID: String) {
    let windowID = owners[tabID]
    if reportRendererGoneOnClose {
      let profileID = closeProfileID
      // The product reports renderer exit on the main thread before close returns.
      MainActor.assumeIsolated {
        self.onRendererGone?(tabID, profileID, "renderer_gone", 0)
      }
    }
    owners[tabID] = nil
    if let windowID { onTabClosed?(tabID, windowID) }
  }

  func destroy(_ id: UUID) { closeTabID(id.uuidString) }
}
