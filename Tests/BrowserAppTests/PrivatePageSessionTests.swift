// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct PrivatePageSessionTests {
  @Test func printRequestMustMatchItsCallbackTab() throws {
    let tabID = UUID()
    let store = BrowserStore(
      privateSession: try BrowserSession.privateWindow(
        sourceProfileID: UUID(), firstTabID: tabID))
    let runtime = PrivatePrintRequestRuntime()
    let page = PrivatePageSession(
      runtime: runtime, contextID: UUID().uuidString,
      windowID: UUID().uuidString, firstTabID: tabID, store: store)
    defer { page.stopSleepingTabWatch() }
    page.tabChanged(
      tabID, url: "https://private.example/", title: "Private page",
      loading: false, back: false, forward: false)
    let requestID = UUID().uuidString
    let payload: [String: Any] = [
      "schemaVersion": 1,
      "id": requestID,
      "profileID": store.session.selectedSpace.profileID.uuidString,
      "tabID": tabID.uuidString,
      "pageURL": "https://private.example/",
      "origin": "https://private.example",
      "frameID": "0123456789abcdef0123456789abcdef",
      "title": "Private page",
    ]

    page.receivePrintRequest(payload, tabID: UUID().uuidString)

    #expect(runtime.printDecisions.map(\.0) == [requestID])
    #expect(runtime.printDecisions.map(\.1) == [false])
    #expect(store.sheet == nil)
  }

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

@MainActor
private final class PrivatePrintRequestRuntime: ARCChromiumRuntime {
  var printDecisions: [(String, Bool)] = []

  override func resolvePrintRequestID(_ requestID: String, accepted: Bool) {
    printDecisions.append((requestID, accepted))
  }
}
