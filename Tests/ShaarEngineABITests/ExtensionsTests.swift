// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarEngineABI

private actor FakeExtensionsTransport: ShaarExtensionsTransport {
  struct Call: Sendable {
    let profileID: UUID
    let windowID: UUID?
    let tabID: UUID?
    let operation: ShaarExtensionsOperation
    let arguments: Data
  }
  private(set) var calls: [Call] = []
  var reply: Data

  init(_ reply: String) { self.reply = Data(reply.utf8) }

  func submitExtensions(
    profileID: UUID, windowID: UUID?, tabID: UUID?, operation: ShaarExtensionsOperation,
    arguments: Data
  ) async throws -> Data {
    calls.append(Call(
      profileID: profileID, windowID: windowID, tabID: tabID,
      operation: operation, arguments: arguments))
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
    #expect(call.windowID == nil)
    #expect(call.tabID == nil)
    #expect(call.operation == .list)
    #expect(
      try JSONSerialization.jsonObject(with: call.arguments) as? [String: Int] == [
        "schemaVersion": 1
      ])
  }

  @Test func actionConsentAndPopupCallsCarryExactOwners() async throws {
    let profile = UUID(), window = UUID(), tab = UUID()
    let fake = FakeExtensionsTransport(#"{"schemaVersion":1,"route":"popup"}"#)
    let adapter = ShaarExtensionsAdapter(
      implementation: .shaar, ardia: FakeArdiaExtensions(), shaar: fake)
    let route = try await adapter.invoke(
      profileID: profile, windowID: window, tabID: tab,
      extensionID: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    #expect(route == .popup)
    let actionCall = try #require(await fake.calls.last)
    #expect(actionCall.profileID == profile)
    #expect(actionCall.windowID == window)
    #expect(actionCall.tabID == tab)
    #expect(actionCall.operation == .action)
    let actionArgs = try #require(JSONSerialization.jsonObject(with: actionCall.arguments)
      as? [String: Any])
    #expect(actionArgs["action"] as? String == "invoke")

    await fake.setReply(#"{"schemaVersion":1,"resolved":true}"#)
    try await adapter.resolveInstallDecision(
      profileID: profile, requestID: "consent-1", accepted: true)
    #expect(await fake.calls.last?.operation == .installDecision)

    await fake.setReply(#"{"schemaVersion":1,"closed":true}"#)
    try await adapter.closePopup(profileID: profile, windowID: window, popupID: "popup-1")
    let closeCall = try #require(await fake.calls.last)
    #expect(closeCall.windowID == window)
    #expect(closeCall.operation == .popupClose)
  }

  @Test func eventDecoderRequiresStableProfileAndOwners() throws {
    let profile = UUID(), window = UUID(), tab = UUID()
    let payload = try JSONSerialization.data(withJSONObject: [
      "schemaVersion": 1, "kind": "extension.installConsentRequested",
      "requestId": "request-1", "extensionId": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "name": "Example", "version": "1.0", "source": "webStore",
      "sourceUrl": "https://chromewebstore.google.com/detail/example",
      "permissions": ["storage"], "hostPermissions": ["https://example.com/*"],
      "permissionsComplete": true,
      "deadline": 1_800_000_000.0, "windowId": window.uuidString.lowercased(),
      "tabId": tab.uuidString.lowercased(),
    ])
    let event = ShaarCopiedEvent(
      sequence: 1, kind: 13, profileID: Data(profile.uuidString.lowercased().utf8),
      sessionID: Data(), windowID: Data(window.uuidString.lowercased().utf8),
      tabID: Data(tab.uuidString.lowercased().utf8), payloadJSON: payload)
    let decoded = try ShaarExtensionsAdapter.decodeEvent(event)
    guard case .consentRequested(let request) = decoded else {
      Issue.record("expected an install consent event")
      return
    }
    #expect(request.profileID == profile)
    #expect(request.windowID == window)
    #expect(request.tabID == tab)
    #expect(request.extensionID == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")

    let foreignOwner = ShaarCopiedEvent(
      sequence: 3, kind: 13, profileID: Data(profile.uuidString.lowercased().utf8),
      sessionID: Data(), windowID: Data(UUID().uuidString.lowercased().utf8),
      tabID: Data(tab.uuidString.lowercased().utf8), payloadJSON: payload)
    #expect(throws: ShaarExtensionsAdapterError.invalidResponse("consent event lacks owner")) {
      try ShaarExtensionsAdapter.decodeEvent(foreignOwner)
    }

    let privateEvent = ShaarCopiedEvent(
      sequence: 2, kind: 13, profileID: Data(profile.uuidString.lowercased().utf8),
      sessionID: Data("private-session".utf8),
      windowID: Data(window.uuidString.lowercased().utf8),
      tabID: Data(tab.uuidString.lowercased().utf8),
      payloadJSON: payload)
    #expect(throws: ShaarExtensionsAdapterError.invalidResponse("invalid extension event")) {
      try ShaarExtensionsAdapter.decodeEvent(privateEvent)
    }
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

  @Test func installAndIncognitoChangesUseTypedManagementSchemas() async throws {
    let profile = UUID()
    let fake = FakeExtensionsTransport(#"{"schemaVersion":1,"accepted":true}"#)
    let adapter = ShaarExtensionsAdapter(
      implementation: .shaar, ardia: FakeArdiaExtensions(), shaar: fake)
    try await adapter.manage(
      profileID: profile,
      action: .install("cccccccccccccccccccccccccccccccc", source: .webStore))
    let install = try #require(await fake.calls.last)
    let installArgs = try #require(JSONSerialization.jsonObject(with: install.arguments)
      as? [String: Any])
    #expect(installArgs["action"] as? String == "install")
    #expect(installArgs["source"] as? String == "webStore")
    #expect(installArgs["extensionId"] as? String == "cccccccccccccccccccccccccccccccc")

    await fake.setReply(#"{"schemaVersion":1,"updated":true}"#)
    try await adapter.manage(
      profileID: profile,
      action: .setIncognitoEnabled("cccccccccccccccccccccccccccccccc", false))
    let incognito = try #require(await fake.calls.last)
    let incognitoArgs = try #require(JSONSerialization.jsonObject(with: incognito.arguments)
      as? [String: Any])
    #expect(incognitoArgs["action"] as? String == "setIncognitoEnabled")
    #expect(incognitoArgs["enabled"] as? Bool == false)
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
