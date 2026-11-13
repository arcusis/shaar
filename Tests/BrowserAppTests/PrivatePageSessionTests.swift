// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct PrivatePageSessionTests {
  @Test func liveTabOwnershipRequiresThePrivateProfileAndAnOpenSession() throws {
    let tabID = UUID()
    let store = BrowserStore(
      privateSession: try BrowserSession.privateWindow(
        sourceProfileID: UUID(), firstTabID: tabID))
    let page = PrivatePageSession(
      runtime: ARCChromiumRuntime(), contextID: UUID().uuidString,
      windowID: UUID().uuidString, firstTabID: tabID, store: store)
    defer { page.stopSleepingTabWatch() }
    let profileID = store.session.selectedSpace.profileID

    #expect(page.ownsLiveTab(tabID, profileID: profileID))
    #expect(!page.ownsLiveTab(tabID, profileID: UUID()))
    page.retireInspectors()
    #expect(!page.ownsLiveTab(tabID, profileID: profileID))
  }

  @Test func failureRemainsVisibleUntilANonBlankURLArrives() throws {
    let tabID = UUID()
    let store = BrowserStore(
      privateSession: try BrowserSession.privateWindow(
        sourceProfileID: UUID(), firstTabID: tabID))
    let page = PrivatePageSession(
      runtime: ARCChromiumRuntime(), contextID: UUID().uuidString,
      windowID: UUID().uuidString, firstTabID: tabID, store: store)
    defer { page.stopSleepingTabWatch() }

    page.navigationFailed("Connection failed")
    page.tabChanged(tabID, url: "about:blank", title: "", loading: false, back: false, forward: false)
    #expect(page.failure == "Connection failed")

    page.tabChanged(
      tabID, url: "https://recovered.example/", title: "Recovered",
      loading: true, back: false, forward: false)
    #expect(page.failure == nil)
  }
}
