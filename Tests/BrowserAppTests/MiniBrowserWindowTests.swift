// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct MiniBrowserWindowTests {
  @Test func addressInputTrimsWhitespaceAndInfersHttpsForBareHosts() throws {
    #expect(
      MiniBrowserController.navigationURL(for: "  example.com/path  ")
        == URL(string: "https://example.com/path"))
    #expect(
      MiniBrowserController.navigationURL(for: " http://example.com ")
        == URL(string: "http://example.com"))
  }

  @Test func explicitUnsupportedSchemesAndSearchTextAreRejected() {
    for input in [
      "", "   ", "javascript:alert(1)", "mailto:person@example.com", "file:///tmp/secret",
      "data:text/html,hello", "search terms", "shaar://settings",
    ] {
      #expect(MiniBrowserController.navigationURL(for: input) == nil, "input: \(input)")
    }
  }

  @Test func existingWebSchemesRemainIntact() throws {
    #expect(
      MiniBrowserController.navigationURL(for: "http://localhost:8080/path")
        == URL(string: "http://localhost:8080/path"))
  }

}
