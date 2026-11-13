// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct PrivatePageSleepingTests {
  @Test func lifecycleEventsSleepBackgroundTabsAndWakeActiveTabs() throws {
    let firstTabID = UUID()
    let store = BrowserStore(
      privateSession: try BrowserSession.privateWindow(
        sourceProfileID: UUID(), firstTabID: firstTabID))
    let page = PrivatePageSession(
      runtime: ARCChromiumRuntime(), contextID: UUID().uuidString,
      windowID: UUID().uuidString, firstTabID: firstTabID, store: store)
    defer { page.stopSleepingTabWatch() }
    store.perform(.open(URL(string: "https://background.example")!))

    page.applyLifecycle(firstTabID, state: "discarded", audible: false, capturing: false)
    #expect(store.sleepingTabIDs == [firstTabID])

    page.applyLifecycle(firstTabID, state: "active", audible: false, capturing: false)
    #expect(store.sleepingTabIDs.isEmpty)

    let selected = try #require(store.session.selectedPage?.tab.id)
    page.applyLifecycle(selected, state: "frozen", audible: false, capturing: false)
    #expect(store.sleepingTabIDs.isEmpty)
  }
}
