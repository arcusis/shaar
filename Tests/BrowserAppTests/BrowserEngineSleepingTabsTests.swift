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
