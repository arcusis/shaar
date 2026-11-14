// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite
struct AgentBridgeModelTests {
  @Test func statusDecoderRejectsBooleansInIntegerFields() throws {
    let valid: [String: Any] = [
      "schemaVersion": 1,
      "enabled": true,
      "port": 1,
      "wsEndpoint": "ws://127.0.0.1:1/devtools/browser/id",
      "connectionCount": 1,
    ]
    #expect(throws: AgentBridgeFailure.self) {
      try AgentBridgeStatus.decode(
        Self.json(valid.merging(["schemaVersion": true]) { _, new in new }))
    }
    #expect(throws: AgentBridgeFailure.self) {
      try AgentBridgeStatus.decode(Self.json(valid.merging(["port": true]) { _, new in new }))
    }
    #expect(throws: AgentBridgeFailure.self) {
      try AgentBridgeStatus.decode(
        Self.json(valid.merging(["connectionCount": true]) { _, new in new }))
    }
  }

  private static func json(_ value: [String: Any]) throws -> [String: Any] {
    let data = try JSONSerialization.data(withJSONObject: value)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}
