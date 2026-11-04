// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@MainActor
@Suite struct ShaarFirstTabProbeTests {
  @Test func missingArgumentsFailBeforeStartingTheEngine() {
    #expect(ShaarFirstTabProbe.run(arguments: []) == 1)
    #expect(ShaarFirstTabProbe.run(arguments: ["--shaar-engine-backend=shaar"]) == 1)
    #expect(
      ShaarFirstTabProbe.run(arguments: [
        "--shaar-engine-backend=shaar", "--probe-framework", "/nonexistent/framework",
      ]) == 1)
  }

  @Test func requestedURLAcceptsNormalizedRootAndRejectsOtherNavigation() {
    let requested = URL(string: "https://example.com")!
    #expect(
      ShaarFirstTabProbe.matchesRequestedURL(
        URL(string: "https://example.com/")!, requested: requested))
    #expect(
      !ShaarFirstTabProbe.matchesRequestedURL(
        URL(string: "https://other.example.com/")!, requested: requested))
    #expect(
      !ShaarFirstTabProbe.matchesRequestedURL(
        URL(string: "https://example.com/other")!, requested: requested))
    #expect(!ShaarFirstTabProbe.matchesRequestedURL(nil, requested: requested))
  }
}
