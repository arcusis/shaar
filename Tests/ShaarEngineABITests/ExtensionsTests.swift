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
  var repliesByProfile: [UUID: Data] = [:]
  var listReply: Data?

  init(_ reply: String) { self.reply = Data(reply.utf8) }

  func submitExtensions(
    profileID: UUID, operation: ShaarExtensionsOperation, arguments: Data
  ) async throws -> Data {
    calls.append(Call(profileID: profileID, operation: operation, arguments: arguments))
    if operation == .list, let listReply { return listReply }
    return repliesByProfile[profileID] ?? reply
  }

  func setReply(_ value: String) { reply = Data(value.utf8) }
  func setReply(_ value: String, for profileID: UUID) {
    repliesByProfile[profileID] = Data(value.utf8)
  }
  func setListReply(_ value: String) { listReply = Data(value.utf8) }
}

@Suite("Shaar extensions adapter")
struct ShaarExtensionsAdapterTests {
  @Test func sharedInstallReportsEveryProfileAndNeverHidesPartialFailure() async throws {
    let first = UUID()
    let second = UUID()
    let fake = FakeExtensionsTransport(#"{"schemaVersion":1,"installed":true}"#)
    let adapter = ShaarExtensionsAdapter(shaar: fake)
    let result = await adapter.installAcrossProfiles(
      extensionID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", approvedVersion: "1.2.3",
      profileIDs: [first, second])
    #expect(result.installed == Set([first, second]))
    #expect(result.failed.isEmpty)
    let calls = await fake.calls
    #expect(Set(calls.map(\.profileID)) == Set([first, second]))
    #expect(calls.allSatisfy { $0.operation == .manage })
    for call in calls {
      let args = try #require(JSONSerialization.jsonObject(with: call.arguments) as? [String: Any])
      #expect(args["action"] as? String == "install")
      #expect(args["source"] as? String == "sharedHome")
      #expect(args["approvedVersion"] as? String == "1.2.3")
    }
    await fake.setReply(#"{"schemaVersion":1,"installed":false}"#, for: second)
    let partial = await adapter.installAcrossProfiles(
      extensionID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", approvedVersion: "1.2.3",
      profileIDs: [first, second])
    #expect(partial.installed == [first])
    #expect(partial.failed == [second])
    #expect(!partial.complete)
    await fake.setReply(#"{"schemaVersion":1,"queued":true}"#, for: second)
    let queued = await adapter.installAcrossProfiles(
      extensionID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", approvedVersion: "1.2.3",
      profileIDs: [first, second])
    #expect(queued.installed == [first])
    #expect(queued.pending == [second])
    #expect(!queued.complete)
  }

  @Test func sharedHomePersistsIntentAndReconcilesNewProfiles() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let first = UUID()
    let next = UUID()
    let id = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    let fake = FakeExtensionsTransport(#"{"schemaVersion":1,"installed":true}"#)
    await fake.setListReply(
      #"{"schemaVersion":1,"extensions":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"Example","version":"1.0","enabled":true,"mayDisable":true,"incognitoEnabled":false,"source":4,"fromWebStore":true}]}"#
    )
    let adapter = ShaarExtensionsAdapter(shaar: fake)
    let home = try ShaarExtensionHome(fileURL: file, adapter: adapter)
    let initial = try await home.recordApprovedInstall(
      id, approvedVersion: "1.0", profileIDs: [first])
    #expect(initial.complete)
    let reopened = try ShaarExtensionHome(fileURL: file, adapter: adapter)
    #expect(await reopened.extensionIDs == [id])
    let result = await reopened.reconcile(profileID: next)
    #expect(result.complete)
    #expect(Set(await fake.calls.map(\.profileID)) == Set([first, next]))
  }

  @Test func sharedHomeRejectsAnInstallWithoutACompletedOrigin() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let fake = FakeExtensionsTransport(#"{"schemaVersion":1,"installed":true}"#)
    await fake.setListReply(#"{"schemaVersion":1,"extensions":[]}"#)
    let adapter = ShaarExtensionsAdapter(shaar: fake)
    let home = try ShaarExtensionHome(fileURL: file, adapter: adapter)
    await #expect(throws: ShaarExtensionsAdapterError.installNotConfirmed) {
      try await home.recordApprovedInstall(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", approvedVersion: "1.0", profileIDs: [UUID()])
    }
    #expect(await home.extensionIDs.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: file.path))
  }

  @Test func sharedHomeRejectsUnpackedOrigin() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let fake = FakeExtensionsTransport(#"{"schemaVersion":1,"installed":true}"#)
    await fake.setListReply(
      #"{"schemaVersion":1,"extensions":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"Local","version":"1.0","enabled":true,"mayDisable":true,"incognitoEnabled":false,"source":4,"fromWebStore":false}]}"#
    )
    let adapter = ShaarExtensionsAdapter(shaar: fake)
    let home = try ShaarExtensionHome(fileURL: file, adapter: adapter)
    await #expect(throws: ShaarExtensionsAdapterError.installNotConfirmed) {
      try await home.recordApprovedInstall(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", approvedVersion: "1.0", profileIDs: [UUID()])
    }
  }

  @Test func shippingDefaultSubmitsToShaar() async throws {
    let profile = UUID()
    let fake = FakeExtensionsTransport(#"{"schemaVersion":1,"extensions":[]}"#)
    let adapter = ShaarExtensionsAdapter(shaar: fake)
    let result = try await adapter.list(profileID: profile)
    #expect(ShaarEngineImplementation.shippingDefault == .shaar)
    #expect(result.isEmpty)
    #expect(await fake.calls.count == 1)
  }

  @Test func listDecodesStrictRowsAndUsesExplicitProfile() async throws {
    let profile = UUID()
    let fake = FakeExtensionsTransport(
      #"{"schemaVersion":1,"extensions":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"Example","version":"2.1","enabled":false,"mayDisable":true,"incognitoEnabled":false,"source":4}]}"#
    )
    let adapter = ShaarExtensionsAdapter(shaar: fake)
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

  @Test func listAcceptsNativeMetadataFields() async throws {
    let fake = FakeExtensionsTransport(
      #"{"schemaVersion":1,"extensions":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"Example","version":"2.1","description":"Details","permissions":["storage"],"hostPermissions":[],"enabled":true,"mayDisable":true,"incognitoEnabled":false,"source":4,"fromWebStore":true}]}"#
    )
    let adapter = ShaarExtensionsAdapter(shaar: fake)
    let result = try await adapter.list(profileID: UUID())
    #expect(result.first?.name == "Example")
    #expect(result.first?.fromWebStore == true)
  }

  @Test func managementActionsAreClosedAndRequireConfirmedResults() async throws {
    let profile = UUID()
    let fake = FakeExtensionsTransport(#"{"schemaVersion":1,"updated":true}"#)
    let adapter = ShaarExtensionsAdapter(shaar: fake)
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

  @Test func extensionConfirmationsRejectNumericBooleanSubstitutes() async throws {
    let fake = FakeExtensionsTransport(#"{"schemaVersion":1,"updated":1}"#)
    let adapter = ShaarExtensionsAdapter(shaar: fake)
    await #expect(throws: ShaarExtensionsAdapterError.mutationNotConfirmed) {
      try await adapter.manage(
        profileID: UUID(),
        action: .setEnabled("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", true))
    }

    let installedProfile = UUID()
    await fake.setReply(#"{"schemaVersion":1,"installed":1}"#)
    let installed = await adapter.installAcrossProfiles(
      extensionID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", approvedVersion: "1.0",
      profileIDs: [installedProfile])
    #expect(installed.installed.isEmpty)
    #expect(installed.failed == [installedProfile])

    let queuedProfile = UUID()
    await fake.setReply(#"{"schemaVersion":1,"queued":1}"#)
    let queued = await adapter.installAcrossProfiles(
      extensionID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", approvedVersion: "1.0",
      profileIDs: [queuedProfile])
    #expect(queued.pending.isEmpty)
    #expect(queued.failed == [queuedProfile])
  }

  @Test func malformedRowsAndInvalidIDsAreRejected() async throws {
    let fake = FakeExtensionsTransport(
      #"{"schemaVersion":1,"extensions":[{"id":"../extension","name":"bad","version":"1","enabled":true,"mayDisable":true,"incognitoEnabled":false,"source":0}]}"#
    )
    let adapter = ShaarExtensionsAdapter(shaar: fake)
    await #expect(throws: ShaarExtensionsAdapterError.invalidResponse("malformed extension row")) {
      try await adapter.list(profileID: UUID())
    }
    await #expect(throws: ShaarExtensionsAdapterError.invalidExtensionID) {
      try await adapter.manage(profileID: UUID(), action: .uninstall("../extension"))
    }
    let invalidInstall = await adapter.installAcrossProfiles(
      extensionID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", approvedVersion: "../1",
      profileIDs: [UUID()])
    #expect(invalidInstall.installed.isEmpty)
    #expect(invalidInstall.failed.count == 1)
  }

  @Test func extensionSourceRejectsBooleanInteger() async throws {
    let fake = FakeExtensionsTransport(
      #"{"schemaVersion":1,"extensions":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"Extension","version":"1","enabled":true,"mayDisable":true,"incognitoEnabled":false,"source":true}]}"#
    )
    await #expect(throws: ShaarExtensionsAdapterError.invalidResponse("malformed extension row")) {
      _ = try await ShaarExtensionsAdapter(shaar: fake).list(profileID: UUID())
    }
  }

  @Test func extensionBooleanFieldsRejectNumericSubstitutes() async throws {
    let fake = FakeExtensionsTransport("")
    let adapter = ShaarExtensionsAdapter(shaar: fake)
    let fields = ["enabled", "mayDisable", "incognitoEnabled", "fromWebStore"]
    for field in fields {
      var row: [String: Any] = [
        "id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "name": "Extension", "version": "1",
        "enabled": true, "mayDisable": true, "incognitoEnabled": false, "source": 4,
        "fromWebStore": true,
      ]
      row[field] = 1
      let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "extensions": [row]])
      await fake.setReply(try #require(String(data: data, encoding: .utf8)))
      await #expect(throws: ShaarExtensionsAdapterError.invalidResponse("malformed extension row")) {
        _ = try await adapter.list(profileID: UUID())
      }
    }
  }

  @Test func extensionListRejectsNumericBooleanFields() async throws {
    let row =
      #"{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"Extension","version":"1","enabled":true,"mayDisable":true,"incognitoEnabled":false,"source":4,"fromWebStore":true}"#
    for invalidRow in [
      row.replacingOccurrences(of: #""enabled":true"#, with: #""enabled":1"#),
      row.replacingOccurrences(of: #""mayDisable":true"#, with: #""mayDisable":0"#),
      row.replacingOccurrences(of: #""incognitoEnabled":false"#, with: #""incognitoEnabled":1"#),
      row.replacingOccurrences(of: #""fromWebStore":true"#, with: #""fromWebStore":0"#),
    ] {
      let fake = FakeExtensionsTransport("{\"schemaVersion\":1,\"extensions\":[\(invalidRow)]}")
      await #expect(throws: ShaarExtensionsAdapterError.invalidResponse("malformed extension row")) {
        _ = try await ShaarExtensionsAdapter(shaar: fake).list(profileID: UUID())
      }
    }
  }

  @Test func extensionListRejectsBooleanSchemaVersion() async throws {
    let fake = FakeExtensionsTransport(#"{"schemaVersion":true,"extensions":[]}"#)
    await #expect(throws: ShaarExtensionsAdapterError.invalidResponse("unsupported schema version"))
    {
      _ = try await ShaarExtensionsAdapter(shaar: fake).list(profileID: UUID())
    }
  }
}
