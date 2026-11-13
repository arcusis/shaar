// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@MainActor
@Suite("DevTools route protocol replies")
struct DevToolsRouteProbeTests {
  @Test func protocolResultRequiresAResultObjectAndNoErrorField() throws {
    #expect(try DevToolsRouteProbe.protocolResult(["result": ["value": 7]])["value"] as? Int == 7)

    for reply: [String: Any] in [
      ["error": ["code": -32601, "message": "method not found"], "result": [:]],
      ["error": NSNull(), "result": [:]],
      ["result": NSNull()],
      ["result": ["unexpected"]],
      [:],
    ] {
      #expect(throws: (any Error).self) {
        try DevToolsRouteProbe.protocolResult(reply)
      }
    }
  }
}
