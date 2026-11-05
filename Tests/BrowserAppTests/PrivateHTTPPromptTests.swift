// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@MainActor @Test func cancelledPrivateHTTPNewTabDoesNotPromptAgain() throws {
  let firstTabID = UUID()
  let session = try BrowserSession.privateWindow(
    sourceProfileID: UUID(), firstTabID: firstTabID)
  let store = BrowserStore(privateSession: session)
  let page = PrivatePageSession(
    runtime: ARCChromiumRuntime(), contextID: UUID().uuidString,
    windowID: UUID().uuidString, firstTabID: firstTabID, store: store)
  let httpURL = try #require(URL(string: "http://example.test/private"))
  let startURL = try #require(URL(string: "about:blank"))

  store.perform(.open(httpURL))
  #expect(page.pendingHTTP == httpURL)
  let pendingTabID = try #require(store.session.selectedPage?.tab.id)
  page.cancelHTTP()
  #expect(page.pendingHTTP == nil)

  store.openTab()
  #expect(page.pendingHTTP == nil)
  #expect(store.session.page(forTabID: pendingTabID)?.tab.url == startURL)
}
