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
}
