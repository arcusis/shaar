// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarEngineABI

private actor FakeExtensionsTransport: ShaarExtensionsTransport {
  struct Call: Sendable {
    let profileID: UUID
    let operation: ShaarExtensionsOperation
    let arguments: Data
  }
  private(set) var calls: [Call] = []
  var reply: Data

  init(_ reply: String) { self.reply = Data(reply.utf8) }

  func submitExtensions(
    profileID: UUID, operation: ShaarExtensionsOperation, arguments: Data
  ) async throws -> Data {
    calls.append(Call(profileID: profileID, operation: operation, arguments: arguments))
    return reply
  }

  func setReply(_ value: String) { reply = Data(value.utf8) }
}

private actor FakeArdiaExtensions: ArdiaExtensionsBackend {
  private(set) var listCalls: [UUID] = []
  private(set) var manageCalls: [(UUID, ShaarExtensionManagementAction)] = []

  func list(profileID: UUID) async throws -> [ShaarExtensionSummary] {
    listCalls.append(profileID)
    return [
      .init(
        id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", name: "Ardia", version: "1.0", enabled: true,
        mayDisable: true, incognitoEnabled: false, source: 1)
    ]
  }

  func manage(profileID: UUID, action: ShaarExtensionManagementAction) async throws {
    manageCalls.append((profileID, action))
  }
}

@Suite("Shaar extensions adapter")
struct ShaarExtensionsAdapterTests {
  @Test func shippingDefaultRemainsArdiaAndDoesNotSubmitToShaar() async throws {
    let profile = UUID()
    let ardia = FakeArdiaExtensions()
    let fake = FakeExtensionsTransport(#"{"schemaVersion":1,"extensions":[]}"#)
    let adapter = ShaarExtensionsAdapter(ardia: ardia, shaar: fake)
    let result = try await adapter.list(profileID: profile)
    #expect(ShaarEngineImplementation.shippingDefault == .ardia)
    #expect(result.first?.name == "Ardia")
    #expect(await fake.calls.isEmpty)
    #expect(await ardia.listCalls == [profile])
  }

  @Test func listDecodesStrictRowsAndUsesExplicitProfile() async throws {
    let profile = UUID()
    let fake = FakeExtensionsTransport(
      #"{"schemaVersion":1,"extensions":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"Example","version":"2.1","enabled":false,"mayDisable":true,"incognitoEnabled":false,"source":4}]}"#
    )
    let adapter = ShaarExtensionsAdapter(
      implementation: .shaar, ardia: FakeArdiaExtensions(), shaar: fake)
    let extensions = try await adapter.list(profileID: profile)
    #expect(
      extensions == [
        .init(
          id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", name: "Example", version: "2.1", enabled: false,
          mayDisable: true, incognitoEnabled: false, source: 4)
      ])
    let call = try #require(await fake.calls.first)
    #expect(call.profileID == profile)
    #expect(call.operation == .list)
    #expect(
      try JSONSerialization.jsonObject(with: call.arguments) as? [String: Int] == [
        "schemaVersion": 1
      ])
  }

  @Test func managementActionsAreClosedAndRequireConfirmedResults() async throws {
    let profile = UUID()
    let fake = FakeExtensionsTransport(#"{"schemaVersion":1,"updated":true}"#)
    let adapter = ShaarExtensionsAdapter(
      implementation: .shaar, ardia: FakeArdiaExtensions(), shaar: fake)
    try await adapter.manage(
      profileID: profile,
      action: .setEnabled("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", true))
    let call = try #require(await fake.calls.first)
    #expect(call.operation == .manage)
    let args = try #require(JSONSerialization.jsonObject(with: call.arguments) as? [String: Any])
    #expect(args["action"] as? String == "setEnabled")
    #expect(args["extensionId"] as? String == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
    #expect(args["enabled"] as? Bool == true)

    await fake.setReply(#"{"schemaVersion":1,"removed":false}"#)
    await #expect(throws: ShaarExtensionsAdapterError.mutationNotConfirmed) {
      try await adapter.manage(
        profileID: profile,
        action: .uninstall("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"))
    }
  }

  @Test func malformedRowsAndInvalidIDsAreRejected() async throws {
    let fake = FakeExtensionsTransport(
      #"{"schemaVersion":1,"extensions":[{"id":"../extension","name":"bad","version":"1","enabled":true,"mayDisable":true,"incognitoEnabled":false,"source":0}]}"#
    )
    let adapter = ShaarExtensionsAdapter(
      implementation: .shaar, ardia: FakeArdiaExtensions(), shaar: fake)
    await #expect(throws: ShaarExtensionsAdapterError.invalidResponse("malformed extension row")) {
      try await adapter.list(profileID: UUID())
    }
    await #expect(throws: ShaarExtensionsAdapterError.invalidExtensionID) {
      try await adapter.manage(profileID: UUID(), action: .uninstall("../extension"))
    }
  }
}
