// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

struct PrintRequestTests {
  private let frameID = "0123456789abcdef0123456789abcdef"

  private func payload() -> [String: Any] {
    [
      "schemaVersion": 1,
      "id": UUID().uuidString,
      "profileID": UUID().uuidString,
      "tabID": UUID().uuidString,
      "pageURL": "https://example.com/page",
      "origin": "https://example.com",
      "frameID": frameID,
      "title": "Article",
    ]
  }

  @Test func acceptsMaximumUTF8FieldSizes() {
    var value = payload()
    value["pageURL"] = "https://e.com/" + String(repeating: "a", count: 4096 - 14)
    value["origin"] = "https://" + String(repeating: "a", count: 2040)
    value["title"] = String(repeating: "é", count: 1024)

    #expect((value["pageURL"] as? String)?.utf8.count == 4096)
    #expect((value["origin"] as? String)?.utf8.count == 2048)
    #expect((value["title"] as? String)?.utf8.count == 2048)
    #expect(PrintRequest(payload: value) != nil)
  }

  @Test func rejectsFieldsOverTheirUTF8ByteLimits() {
    var longPage = payload()
    longPage["pageURL"] = "https://e.com/" + String(repeating: "a", count: 4096 - 14 + 1)
    #expect(PrintRequest(payload: longPage) == nil)

    var longOrigin = payload()
    longOrigin["origin"] = "https://" + String(repeating: "a", count: 2041)
    #expect(PrintRequest(payload: longOrigin) == nil)

    var longTitle = payload()
    longTitle["title"] = String(repeating: "é", count: 1025)
    #expect(PrintRequest(payload: longTitle) == nil)
  }

  @Test func rejectsOriginsWithCredentialsQueryOrFragment() {
    for origin in [
      "https://user@example.com",
      "https://user:secret@example.com",
      "https://example.com/?x=1",
      "https://example.com#section",
    ] {
      var value = payload()
      value["origin"] = origin
      #expect(PrintRequest(payload: value) == nil)
    }
  }

  @Test func frameTokenRequiresExactlyThirtyTwoASCIIHexCharacters() {
    for token in [
      String(repeating: "a", count: 31),
      String(repeating: "a", count: 33),
      "0123456789abcdef0123456789abcdefé",
      "0123456789abcdef0123456789abcdef/",
    ] {
      var value = payload()
      value["frameID"] = token
      #expect(PrintRequest(payload: value) == nil)
    }
  }
}
