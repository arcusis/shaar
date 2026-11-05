// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridgeVerification
import Foundation
import Testing

@Suite("Private Shaar evaluation reply")
struct PrivateProbeEvaluationTests {
  @Test func extractsJSONValueFromScopedDevToolsReply() throws {
    let reply: [String: Any] = [
      "schemaVersion": 1,
      "result": ["result": ["value": ["fixture": "v1", "private": true]]],
    ]
    let json = try #require(ARCProbePrivateEvaluationJSON(reply))
    let value = try #require(
      JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    #expect(value["fixture"] as? String == "v1")
    #expect(value["private"] as? Bool == true)
  }

  @Test func rejectsPrivateEvaluationExceptions() {
    let reply: [String: Any] = [
      "schemaVersion": 1,
      "result": ["exceptionDetails": ["text": "denied"]],
    ]
    #expect(ARCProbePrivateEvaluationJSON(reply) == nil)
  }
}
