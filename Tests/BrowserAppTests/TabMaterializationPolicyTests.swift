// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite
struct TabMaterializationPolicyTests {
  @Test @MainActor func selectingSavedPlaceholderOpensOnlyThatTab() async throws {
    let profile = BrowserProfile(name: "Lazy tabs")
    let selected = BrowserTab(url: URL(string: "https://selected.example")!)
    let background = BrowserTab(url: URL(string: "https://background.example")!)
    let untouched = BrowserTab(url: URL(string: "https://untouched.example")!)
    let space = BrowserSpace(
      profileID: profile.id, name: "Test", symbol: "globe", tint: .ocean,
      tabs: [selected, background, untouched], selectedTabID: selected.id)
    let session = try BrowserSession(
      profiles: [profile], spaces: [space], selectedSpaceID: space.id)
    let store = BrowserStore(session: session)
    let runtime = LazyTabTestRuntime()
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: runtime), store: store, lazyPinnedTabs: true)
    defer { engine.suspensionTask?.cancel() }
    store.library.onLoad = nil

    engine.reconcile()
    for _ in 0..<100 where runtime.opened.isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(runtime.opened == [selected.id.uuidString])
    #expect(engine.liveTabs == [selected.id])

    store.perform(.tab(space: space.id, tab: background.id))
    engine.reconcile()
    #expect(runtime.opened == [selected.id.uuidString, background.id.uuidString])
    #expect(engine.liveTabs == [selected.id, background.id])

    store.perform(.tab(space: space.id, tab: selected.id))
    engine.reconcile()
    #expect(runtime.opened.count == 2)
    #expect(!engine.liveTabs.contains(untouched.id))
  }

  @Test func eagerProbeModeMaterializesSelectedAndBackgroundTabs() {
    #expect(
      TabMaterializationPolicy.decision(isSelected: true, isLive: false, lazy: false)
        == .materialize)
    #expect(
      TabMaterializationPolicy.decision(isSelected: false, isLive: false, lazy: false)
        == .materialize)
  }

  @Test func lazyProductionModeMaterializesOnlySelectedTabRegardlessOfPinState() {
    #expect(
      TabMaterializationPolicy.decision(isSelected: true, isLive: false, lazy: true) == .materialize
    )
    #expect(
      TabMaterializationPolicy.decision(isSelected: false, isLive: false, lazy: true) == .deferred)
  }

  @Test func loadedTabStaysLiveAcrossSelectionChangesUntilRemoved() {
    #expect(
      TabMaterializationPolicy.decision(isSelected: true, isLive: false, lazy: true) == .materialize
    )
    #expect(
      TabMaterializationPolicy.decision(isSelected: false, isLive: true, lazy: true) == .keepLive)
    #expect(
      TabMaterializationPolicy.decision(isSelected: false, isLive: false, lazy: true) == .deferred)
  }

  @Test func keepAliveBackgroundTabMaterializesWithoutSelection() {
    #expect(
      TabMaterializationPolicy.decision(
        isSelected: false, isLive: false, lazy: true, keepAlive: true) == .materialize)
  }
}

private final class LazyTabTestRuntime: ARCChromiumRuntime {
  nonisolated(unsafe) var opened: [String] = []

  override func loadProfileID(_ profileID: String, completion: @escaping (Error?) -> Void) {
    completion(nil)
  }

  override func openTabID(_ tabID: String, profileID: String, windowID: String, url: String) throws
  {
    opened.append(tabID)
  }

  override func extensions(forProfileID profileID: String) -> [[String: Any]] { [] }
}
