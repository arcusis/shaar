// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserRuntimeEventsTests {
  @Test func nativeTabCloseCallbackUsesTheBoundWindowOwner() throws {
    let runtime = ARCChromiumRuntime()
    let events = BrowserRuntimeEvents(runtime: runtime)
    let owner = BrowserRuntimeClient(windowID: "owner") { [] }
    let other = BrowserRuntimeClient(windowID: "other") { [] }
    try events.router.register(owner)
    try events.router.register(other)
    #expect(events.router.bindTab("tab", windowID: owner.windowID))
    var closes: [String] = []
    owner.onTabClosed = { id, window in closes.append("\(window):\(id)") }
    other.onTabClosed = { id, window in closes.append("\(window):\(id)") }

    runtime.onTabClosed?("tab", other.windowID)
    runtime.onTabClosed?("tab", owner.windowID)
    runtime.onTabClosed?("tab", owner.windowID)

    #expect(closes == ["owner:tab"])
    #expect(events.router.tabOwnerWindowID(for: "tab") == nil)
  }
}
