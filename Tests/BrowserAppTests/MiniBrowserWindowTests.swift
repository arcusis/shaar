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
  }

  @Test func explicitUnsupportedSchemesAndSearchTextAreRejected() {
    for input in [
      "javascript:alert(1)",
      "mailto:person@example.com",
      "file:///tmp/secret",
      "data:text/html,hello",
      "search terms",
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
