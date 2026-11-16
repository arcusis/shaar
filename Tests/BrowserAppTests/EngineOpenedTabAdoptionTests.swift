// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct EngineOpenedTabAdoptionTests {
  @Test func engineOpenedWelcomeTabIsPlacedAfterTheEventCallbackReturns() async throws {
    let (store, opener) = try makeStore()
    let runtime = EngineOpenedTabRuntime()
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: runtime), windowID: "welcome-window", store: store,
      presentsNativePanels: false)
    defer { engine.suspensionTask?.cancel() }
    store.library.onLoad = nil
    engine.reconcile()
    try await waitUntilReady(engine, runtime: runtime, opener: opener)

    let welcome = UUID()
    let profile = store.session.selectedSpace.profileID.uuidString
    runtime.owners[welcome.uuidString] = engine.windowID
    let placesBefore = runtime.placements.count
    runtime.insideEngineEvent = true
    runtime.onNewTab?(
      welcome.uuidString, profile, "https://bitwarden.com/browser-start", opener.id.uuidString, true
    )
    runtime.insideEngineEvent = false

    #expect(runtime.reentrantPlaces == 0)
    #expect(runtime.placements.count == placesBefore)
    #expect(store.session.page(forTabID: welcome)?.tab.url.host() == "bitwarden.com")
    #expect(engine.liveTabs.contains(welcome))

    for _ in 0..<40 where runtime.placements.count == placesBefore {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(runtime.reentrantPlaces == 0)
    let placed = try #require(runtime.placements.last)
    #expect(placed.contains(opener.id.uuidString))
    #expect(placed.contains(welcome.uuidString))
    #expect(runtime.placements.count == placesBefore + 1)
  }

  @Test func rejectedEngineOpenedTabIsDiscardedAfterTheEventCallbackReturns() async throws {
    let (store, opener) = try makeStore()
    let runtime = EngineOpenedTabRuntime()
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: runtime), windowID: "welcome-window", store: store,
      presentsNativePanels: false)
    defer { engine.suspensionTask?.cancel() }
    store.library.onLoad = nil
    engine.reconcile()
    try await waitUntilReady(engine, runtime: runtime, opener: opener)

    let rejected = UUID()
    runtime.owners[rejected.uuidString] = engine.windowID
    runtime.insideEngineEvent = true
    runtime.onNewTab?(
      rejected.uuidString, store.session.selectedSpace.profileID.uuidString,
      "chrome-extension://nngceckbapebfimnlniiiahkandclblb/welcome.html", opener.id.uuidString, true
    )
    runtime.insideEngineEvent = false

    #expect(runtime.reentrantDiscards == 0)
    #expect(runtime.discards.isEmpty)
    #expect(store.session.page(forTabID: rejected) == nil)
    for _ in 0..<40 where runtime.discards.isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(runtime.discards == [rejected.uuidString])
    #expect(runtime.reentrantDiscards == 0)
  }

  private func waitUntilReady(
    _ engine: BrowserEngine, runtime: EngineOpenedTabRuntime, opener: BrowserTab
  ) async throws {
    for _ in 0..<40 where !engine.liveTabs.contains(opener.id) || runtime.placements.isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(engine.liveTabs.contains(opener.id))
    #expect(!runtime.placements.isEmpty)
  }

  private func makeStore() throws -> (BrowserStore, BrowserTab) {
    let profile = BrowserProfile(name: "Extensions")
    let opener = BrowserTab(url: URL(string: "https://chromewebstore.google.com/detail/bitwarden")!)
    let space = BrowserSpace(
      profileID: profile.id, name: "Test", symbol: "globe", tint: .ocean,
      tabs: [opener], selectedTabID: opener.id)
    return (
      BrowserStore(
        session: try BrowserSession(
          profiles: [profile], spaces: [space], selectedSpaceID: space.id)), opener
    )
  }
}

private final class EngineOpenedTabRuntime: ARCChromiumRuntime, @unchecked Sendable {
  nonisolated(unsafe) var owners: [String: String] = [:]
  nonisolated(unsafe) var placements: [[String]] = []
  nonisolated(unsafe) var discards: [String] = []
  nonisolated(unsafe) var insideEngineEvent = false
  nonisolated(unsafe) var reentrantPlaces = 0
  nonisolated(unsafe) var reentrantDiscards = 0

  override func isWindowOpenID(_ windowID: String) -> Bool { true }

  override func loadProfileID(_ profileID: String, completion: @escaping (Error?) -> Void) {
    completion(nil)
  }

  override func openTabID(_ tabID: String, profileID: String, windowID: String, url: String) throws
  {
    owners[tabID] = windowID
  }

  override func windowID(forTabID tabID: String) -> String? { owners[tabID] }

  override func placeTabIDs(
    _ tabIDs: [String], pinnedIDs: [String], profileID: String, windowID: String
  ) -> Bool {
    if insideEngineEvent { reentrantPlaces += 1 }
    placements.append(tabIDs)
    return true
  }

  override func discardTabID(_ tabID: String) {
    if insideEngineEvent { reentrantDiscards += 1 }
    discards.append(tabID)
    owners[tabID] = nil
  }

  override func extensions(forProfileID profileID: String) -> [[String: Any]] { [] }

  override func refreshDownloads(forProfileID profileID: String) {}
}
