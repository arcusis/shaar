// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineABI
import Testing

@testable import ShaarVerification

private actor ProbeExtensionsTransport: ShaarExtensionsTransport {
  let first: UUID
  let second: UUID
  var secondInstalled = false
  var secondEnabled = true

  init(first: UUID, second: UUID) {
    self.first = first
    self.second = second
  }

  func submitExtensions(
    profileID: UUID, operation: ShaarExtensionsOperation, arguments: Data
  ) async throws -> Data {
    let input = try #require(JSONSerialization.jsonObject(with: arguments) as? [String: Any])
    if operation == .list {
      if profileID == second && !secondInstalled {
        return Data(#"{"schemaVersion":1,"extensions":[]}"#.utf8)
      }
      let enabled = profileID == first || secondEnabled ? "true" : "false"
      return Data(
        #"{"schemaVersion":1,"extensions":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"Fixture","version":"1.2","enabled":\#(enabled),"mayDisable":true,"incognitoEnabled":false,"source":4}]}"#
          .utf8)
    }
    if input["action"] as? String == "install" {
      if profileID == second {
        secondInstalled = true
        return Data(#"{"schemaVersion":1,"queued":true}"#.utf8)
      }
      return Data(#"{"schemaVersion":1,"installed":true}"#.utf8)
    }
    if input["action"] as? String == "setEnabled" && profileID == second {
      secondEnabled = input["enabled"] as? Bool == true
      return Data(#"{"schemaVersion":1,"updated":true}"#.utf8)
    }
    throw ProbeFailure.unexpectedOperation
  }

  enum ProbeFailure: Error { case unexpectedOperation }
}

private struct ProbeUnusedArdia: ArdiaExtensionsBackend {
  func list(profileID: UUID) async throws -> [ShaarExtensionSummary] { [] }
  func manage(profileID: UUID, action: ShaarExtensionManagementAction) async throws {}
}

@Suite("Shared extension hidden probe")
struct SharedExtensionProbeTests {
  @Test func queuedSecondProfilePreservesFirstProfileEnableState() async throws {
    let first = UUID()
    let second = UUID()
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let transport = ProbeExtensionsTransport(first: first, second: second)
    let adapter = ShaarExtensionsAdapter(
      implementation: .shaar, ardia: ProbeUnusedArdia(), shaar: transport)
    let home = try ShaarExtensionHome(fileURL: file, adapter: adapter)
    let probe = SharedExtensionProbe(
      adapter: adapter, home: home,
      extensionID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", approvedVersion: "1.2",
      firstProfile: first, secondProfile: second)
    let checks = try await probe.run()
    #expect(checks.count == 2)
    #expect(await transport.secondInstalled)
    #expect(await !transport.secondEnabled)
  }
}
