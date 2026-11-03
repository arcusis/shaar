// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct TabSuspensionTests {
  @Test func inactiveTabsSuspendAfterFiveMinutesAndRestoreScroll() throws {
    let active = BrowserTab(url: URL(string: "https://active.example")!)
    let pinned = BrowserTab(url: URL(string: "https://pinned.example")!, isPinned: true)
    let playing = BrowserTab(url: URL(string: "https://playing.example")!)
    let inactive = BrowserTab(url: URL(string: "https://inactive.example")!)
    let (store, engine, runtime) = try makeEngine(tabs: [active, pinned, playing, inactive])
    defer { engine.suspensionTask?.cancel() }
    engine.liveTabs = Set([active, pinned, playing, inactive].map(\.id))
    #expect(engine.events.router.bindTab(inactive.id.uuidString, windowID: engine.windowID))
    store.media.update(playing.id, state: MediaSessionState(playbackState: .playing))

    let start = Date(timeIntervalSince1970: 1_800_000_000)
    engine.suspendInactiveTabs(now: start)
    #expect(runtime.evaluatedScripts.isEmpty)

    engine.suspendInactiveTabs(now: start.addingTimeInterval(5 * 60 + 1))
    #expect(runtime.discardedTabIDs == [inactive.id.uuidString])
    #expect(!engine.liveTabs.contains(inactive.id))
    #expect(engine.liveTabs.contains(pinned.id))
    #expect(engine.liveTabs.contains(playing.id))
    #expect(runtime.evaluatedScripts.count == 1)
    #expect(runtime.evaluatedScripts[0].contains("scrollX"))

    engine.restoreSuspendedScrollPosition(for: inactive.id)
    #expect(runtime.evaluatedScripts.count == 2)
    #expect(runtime.evaluatedScripts[1].contains("scrollTo(18"))
    #expect(runtime.evaluatedScripts[1].contains(",420"))
  }

  @Test func restorePreservesNegativeRTLHorizontalScroll() throws {
    let active = BrowserTab(url: URL(string: "https://active.example")!)
    let inactive = BrowserTab(url: URL(string: "https://rtl.example")!)
    let (store, engine, runtime) = try makeEngine(tabs: [active, inactive])
    defer { engine.suspensionTask?.cancel() }
    engine.liveTabs = Set([active.id, inactive.id])
    runtime.evaluationResult = "{\"x\":-240,\"y\":420}"

    let start = Date(timeIntervalSince1970: 1_800_000_000)
    engine.suspendInactiveTabs(now: start)
    engine.suspendInactiveTabs(now: start.addingTimeInterval(5 * 60 + 1))
    engine.restoreSuspendedScrollPosition(for: inactive.id)

    #expect(runtime.evaluatedScripts.last?.contains("scrollTo(-240") == true)
    _ = store
  }

  private func makeEngine(tabs: [BrowserTab]) throws -> (
    BrowserStore, BrowserEngine, SuspensionTestRuntime
  ) {
    let profile = BrowserProfile(name: "Suspension test")
    let space = BrowserSpace(
      profileID: profile.id, name: "Test", symbol: "globe", tint: .ocean,
      tabs: tabs, selectedTabID: tabs[0].id)
    let session = try BrowserSession(
      profiles: [profile], spaces: [space], selectedSpaceID: space.id)
    let store = BrowserStore(session: session)
    let runtime = SuspensionTestRuntime()
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: runtime), store: store)
    return (store, engine, runtime)
  }
}

private final class SuspensionTestRuntime: ARCChromiumRuntime {
  nonisolated(unsafe) var evaluatedScripts: [String] = []
  nonisolated(unsafe) var discardedTabIDs: [String] = []
  nonisolated(unsafe) var evaluationResult = "{\"x\":18,\"y\":420}"

  override func evaluate(
    inTabID tabID: String, script: String,
    completion: @escaping @Sendable (String?) -> Void
  ) {
    evaluatedScripts.append(script)
    completion(evaluationResult)
  }

  override func discardTabID(_ tabID: String) {
    discardedTabIDs.append(tabID)
    onTabClosed?(tabID)
  }
}
