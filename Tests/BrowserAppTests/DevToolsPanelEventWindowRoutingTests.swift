// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct DevToolsPanelEventWindowRoutingTests {
  @Test func panelEventsRequireTheNativeWindowThatOwnsTheTab() throws {
    let runtime = DevToolsPanelEventRuntime()
    let events = BrowserRuntimeEvents(runtime: runtime)
    let owner = BrowserRuntimeClient(windowID: "owner") { [] }
    let other = BrowserRuntimeClient(windowID: "other") { [] }
    try events.router.register(owner)
    try events.router.register(other)
    #expect(events.router.bindTab("tab", windowID: owner.windowID))
    runtime.windows["tab"] = owner.windowID

    let payload = Data("{\"kind\":\"console\"}".utf8)
    var ownerPayloads: [Data] = []
    var ownerSequences: [UInt64] = []
    var otherEventCount = 0
    owner.onDevToolsPanelEvent = { _, _, data, sequence in
      ownerPayloads.append(data)
      ownerSequences.append(sequence)
    }
    other.onDevToolsPanelEvent = { _, _, _, _ in otherEventCount += 1 }

    runtime.onDevToolsPanelEvent?("tab", "profile", owner.windowID, payload, 7)
    runtime.onDevToolsPanelEvent?("tab", "profile", other.windowID, payload, 8)
    runtime.windows["tab"] = other.windowID
    runtime.onDevToolsPanelEvent?("tab", "profile", other.windowID, payload, 9)

    #expect(ownerPayloads == [payload])
    #expect(ownerSequences == [7])
    #expect(otherEventCount == 0)
  }
}

@MainActor
private final class DevToolsPanelEventRuntime: ARCChromiumRuntime {
  var windows: [String: String] = [:]

  override func windowID(forTabID tabID: String) -> String? {
    windows[tabID]
  }
}
