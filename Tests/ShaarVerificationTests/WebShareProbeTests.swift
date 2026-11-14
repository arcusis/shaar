// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite("Web Share probe JavaScript strings")
struct WebShareProbeTests {
  @Test func titleValuesRoundTripAsSingleJavaScriptStrings() throws {
    for value in [
      "plain title",
      "quotes: \"double\" and 'single'",
      "line one\nline two\r\ttab",
      "script-like: \" ); alert(1); //",
      "unicode: \u{2028}\u{2029} café",
    ] {
      let encoded = WebShareProbe.javaScriptString(value)
      let decoded =
        try JSONSerialization.jsonObject(
          with: Data("[\(encoded)]".utf8)) as? [String]
      #expect(decoded == [value])
    }
  }

  @MainActor
  @Test func shareOriginDropsPagePathQueryFragmentAndCredentials() throws {
    let page = URL(string: "http://user:secret@127.0.0.1:48000/account?token=local#section")!
    let origin = try #require(WebShareProbe.originURL(for: page))
    let components = try #require(URLComponents(url: origin, resolvingAgainstBaseURL: false))

    #expect(components.scheme == "http")
    #expect(components.host == "127.0.0.1")
    #expect(components.port == 48000)
    #expect(components.path.isEmpty)
    #expect(components.query == nil)
    #expect(components.fragment == nil)
    #expect(components.user == nil)
    #expect(components.password == nil)
  }
}
