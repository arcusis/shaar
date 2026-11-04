// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineABI
import Testing

@testable import ArcusisBrowser
@testable import ShaarVerification

private actor ProbeSiteDataEngine: ShaarSiteDataTransport, ShaarSiteDataPageFixture {
  private var blocked: [UUID: Bool] = [:]
  private var permissions: Set<UUID> = []
  private var data: [UUID: ShaarSiteDataSnapshot] = [:]

  func seed(profileID: UUID, origin: String) async throws {
    data[profileID] = ShaarSiteDataSnapshot(cookie: "siteControl=kept", storage: "kept")
  }

  func snapshot(profileID: UUID, origin: String) async throws -> ShaarSiteDataSnapshot {
    data[profileID] ?? ShaarSiteDataSnapshot(cookie: nil, storage: nil)
  }

  func submit(
    profileID: UUID, operation: ShaarSiteDataOperation, arguments: Data
  ) async throws -> Data {
    let args = try JSONSerialization.jsonObject(with: arguments) as? [String: Any] ?? [:]
    let body: [String: Any]
    switch operation {
    case .thirdPartyCookiesGet:
      body = ["schemaVersion": 1, "blocked": blocked[profileID] ?? false, "managed": false]
    case .thirdPartyCookiesSet:
      blocked[profileID] = args["blocked"] as? Bool ?? false
      body = ["schemaVersion": 1, "blocked": blocked[profileID] ?? false, "managed": false]
    case .settingsSet:
      permissions.insert(profileID)
      body = ["schemaVersion": 1, "value": "allow", "isDefault": false]
    case .settingsGet:
      body = [
        "schemaVersion": 1,
        "settings": [
          "camera": [
            "value": permissions.contains(profileID) ? "allow" : "ask",
            "isDefault": !permissions.contains(profileID),
          ]
        ],
      ]
    case .settingsOrigins:
      body = [
        "schemaVersion": 1,
        "origins": permissions.contains(profileID) ? ["https://example.test"] : [],
      ]
    case .settingsReset:
      permissions.remove(profileID)
      body = ["schemaVersion": 1, "resetCount": 1]
    case .browsingDataClear:
      data[profileID] = ShaarSiteDataSnapshot(cookie: nil, storage: nil)
      body = ["schemaVersion": 1, "clearedTypes": args["types"] ?? [], "complete": true]
    default:
      throw CocoaError(.featureUnsupported)
    }
    return try JSONSerialization.data(withJSONObject: body)
  }
}

@MainActor private final class ProbeProfiles: ShaarSettingsProfileManaging {
  func open(profileID: UUID) async throws {}
  func delete(profileID: UUID) async throws {}
}

@Suite @MainActor
struct ShaarProfilePrivacyProbeTests {
  @Test func hiddenProbeChecksThreeActionsAgainstUntouchedSecondProfile() async throws {
    let engine = ProbeSiteDataEngine()
    let first = UUID()
    let second = UUID()
    let backend = ShaarProfileSettings(transport: engine, profiles: ProbeProfiles())
    let probe = ShaarProfilePrivacyProbe(
      backend: backend, transport: engine, fixture: engine,
      first: first, second: second, origin: "https://example.test")
    let checks = try await probe.run()
    #expect(checks.count == 3)
    #expect(
      try await engine.snapshot(profileID: first, origin: "https://example.test")
        == ShaarSiteDataSnapshot(cookie: nil, storage: nil))
    #expect(
      try await engine.snapshot(profileID: second, origin: "https://example.test")
        == ShaarSiteDataSnapshot(cookie: "siteControl=kept", storage: "kept"))
  }
}
