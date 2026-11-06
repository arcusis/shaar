// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineABI

@testable import ArcusisBrowser

@MainActor
struct ShaarPhase2FixtureTransport: ShaarPhase2Transport {
  static let fiveMiBSource: String = {
    let line = String(repeating: "x", count: 99) + "\n"
    return String(repeating: line, count: 52_428) + String(repeating: "x", count: 80)
  }()

  var available = true
  var response: (ShaarDevToolsPhase2Command) throws -> [String: Any]

  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarPhase2Message> {
    AsyncStream { continuation in
      continuation.yield(available ? .available : .unavailable)
      continuation.finish()
    }
  }

  func execute(_ command: ShaarDevToolsPhase2Command, for target: SiteControlTarget) async throws
    -> ShaarDevToolsPhase2Reply
  {
    var payload = try response(command)
    payload["schemaVersion"] = 1
    payload["commandID"] = command.id
    payload["truncated"] = false
    let data = try JSONSerialization.data(withJSONObject: payload)
    guard let reply = ShaarDevToolsPhase2Reply.decode(data, command: command) else {
      throw FixtureError.invalidReply
    }
    return reply
  }

  enum FixtureError: Error { case invalidReply }
}
