// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct HTTPAuthRequestTests {
  @Test func selectedChallengeSubmitsCredentialsOnlyOnce() throws {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://example.test/protected")!))
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let request = try #require(
      HTTPAuthRequest(payload: [
        "id": "auth-1", "tabID": tab.id.uuidString,
        "profileID": store.session.selectedSpace.profileID.uuidString,
        "windowID": "window-1", "host": "example.test", "realm": "Members",
      ]))
    var decisions: [(String?, String?)] = []
    store.onHTTPAuthDecision = { _, username, password in
      decisions.append((username, password))
    }
    #expect(store.requestHTTPAuth(request))
    #expect(store.sheet?.id == request.sheetID)
    store.resolveHTTPAuth(request, username: "member", password: "secret")
    store.resolveHTTPAuth(request, username: "again", password: "again")
    #expect(decisions.count == 1)
    #expect(decisions[0].0 == "member")
    #expect(decisions[0].1 == "secret")
    #expect(store.sheet == nil)
  }

  @Test func parsesBoundedBasicAuthPromptFields() throws {
    let id = UUID().uuidString
    let tab = UUID().uuidString
    let profile = UUID().uuidString
    let request = try #require(
      HTTPAuthRequest(
        payload: [
          "id": id, "tabID": tab, "profileID": profile, "windowID": "window-1",
          "host": "example.test", "realm": "Members",
        ]))
    #expect(request.host == "example.test")
    #expect(request.realm == "Members")
    #expect(request.sheetID == "http-auth-\(id)")
  }

  @Test func rejectsMalformedOrOversizedPromptFields() {
    let base: [String: Any] = [
      "id": "1", "tabID": UUID().uuidString, "profileID": UUID().uuidString,
      "windowID": "window-1",
      "host": "example.test", "realm": "Members",
    ]
    #expect(HTTPAuthRequest(payload: base) != nil)
    #expect(HTTPAuthRequest(payload: base.merging(["host": ""]) { _, new in new }) == nil)
    #expect(
      HTTPAuthRequest(
        payload: base.merging(["realm": String(repeating: "x", count: 513)]) { _, new in new })
        == nil)
    #expect(HTTPAuthRequest(payload: base.merging(["id": ""]) { _, new in new }) == nil)
  }
}
