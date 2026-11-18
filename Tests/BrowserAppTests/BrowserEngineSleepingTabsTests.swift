// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserEngineSleepingTabsTests {
  @Test func sleepingCandidatesSupportTheBaseRuntime() throws {
    let tab = BrowserTab(url: URL(string: "https://base-runtime.example")!)
    let profile = BrowserProfile(name: "Base runtime")
    let space = BrowserSpace(
      profileID: profile.id, name: "Test", symbol: "globe", tint: .ocean,
      tabs: [tab], selectedTabID: tab.id)
    let session = try BrowserSession(
      profiles: [profile], spaces: [space], selectedSpaceID: space.id)
    let store = BrowserStore(session: session)
    let runtime = ARCChromiumRuntime()
    let engine = try BrowserEngine(events: BrowserRuntimeEvents(runtime: runtime), store: store)
    defer { engine.suspensionTask?.cancel() }
    engine.memoryPressureSource?.cancel()
    engine.memoryPressureSource = nil

    let candidates = engine.sleepingCandidates(in: store)

    #expect(candidates.map(\.id) == [tab.id])
    #expect(candidates[0].host == "base-runtime.example")
    #expect(!candidates[0].hasDeveloperTools)
    #expect(!candidates[0].isPlaying)
    #expect(!candidates[0].isCapturing)
    #expect(!candidates[0].profileIsDownloading)
  }

  @Test func sleepingSplitPaneIsWokenInsteadOfMarkedAsleep() throws {
    var session = BrowserSession.fresh()
    let firstResult = session.open(URL(string: "https://first.example")!)
    let first = try #require(firstResult)
    let secondResult = session.open(URL(string: "https://second.example")!)
    let second = try #require(secondResult)
    let store = BrowserStore(session: session)
    store.splitTabs(first, second)
    let runtime = SleepingTabsTestRuntime()
    let engine = try BrowserEngine(events: BrowserRuntimeEvents(runtime: runtime), store: store)
    defer { engine.suspensionTask?.cancel() }
    engine.memoryPressureSource?.cancel()
    engine.memoryPressureSource = nil

    engine.acceptSleep(second)

    #expect(runtime.woken == [second.uuidString])
    #expect(store.sleepingTabIDs.isEmpty)
  }
}

@MainActor
private final class SleepingTabsTestRuntime: ARCChromiumRuntime {
  var woken: [String] = []

  override func wakeTabID(
    _ tabID: String, completion: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    woken.append(tabID)
    completion(true)
  }
}
