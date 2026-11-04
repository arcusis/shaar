// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineABI
import Testing

@testable import ArcusisBrowser

private actor SettingsExtensionsTransport: ShaarExtensionsTransport {
  var calls: [(UUID, ShaarExtensionsOperation, Data)] = []
  let profiles: [UUID: Bool]
  let missing: Set<UUID>

  init(profiles: [UUID: Bool], missing: Set<UUID> = []) {
    self.profiles = profiles
    self.missing = missing
  }

  func submitExtensions(
    profileID: UUID, operation: ShaarExtensionsOperation, arguments: Data
  ) async throws -> Data {
    calls.append((profileID, operation, arguments))
    if operation == .list {
      if missing.contains(profileID) {
        return Data(#"{"schemaVersion":1,"extensions":[]}"#.utf8)
      }
      let enabled = profiles[profileID] == true ? "true" : "false"
      return Data(
        #"{"schemaVersion":1,"extensions":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"Example","version":"1.2","enabled":\#(enabled),"mayDisable":true,"incognitoEnabled":false,"source":4}]}"#
          .utf8)
    }
    return Data(#"{"schemaVersion":1,"updated":true}"#.utf8)
  }
}

private struct UnusedArdiaExtensions: ArdiaExtensionsBackend {
  func list(profileID: UUID) async throws -> [ShaarExtensionSummary] { [] }
  func manage(profileID: UUID, action: ShaarExtensionManagementAction) async throws {}
}

@Suite("Shared extension Settings")
struct SharedExtensionSettingsTests {
  @Test @MainActor func oneInstallHasIndependentProfileToggles() async throws {
    let first = UUID()
    let second = UUID()
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let transport = SettingsExtensionsTransport(profiles: [first: true, second: false])
    let adapter = ShaarExtensionsAdapter(
      implementation: .shaar, ardia: UnusedArdiaExtensions(), shaar: transport)
    let home = try ShaarExtensionHome(fileURL: file, adapter: adapter)
    _ = try await home.recordApprovedInstall(
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", approvedVersion: "1.2", profileIDs: [])
    let model = SharedExtensionSettingsModel(
      home: home, adapter: adapter, profiles: { [first: "Work", second: "Personal"] })

    await model.reload()
    let row = try #require(model.rows.first)
    #expect(model.rows.count == 1)
    #expect(row.name == "Example")
    #expect(row.profiles[first]?.enabled == true)
    #expect(row.profiles[second]?.enabled == false)
    await model.setEnabled(true, extensionID: row.id, profileID: second)
    let calls = await transport.calls
    let mutations = calls.filter { $0.1 == .manage }
    #expect(mutations.count == 1)
    #expect(mutations.first?.0 == second)
  }

  @Test @MainActor func failedProfileInstallRemainsVisible() async throws {
    let first = UUID()
    let second = UUID()
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let transport = SettingsExtensionsTransport(
      profiles: [first: true, second: false], missing: [second])
    let adapter = ShaarExtensionsAdapter(
      implementation: .shaar, ardia: UnusedArdiaExtensions(), shaar: transport)
    let home = try ShaarExtensionHome(fileURL: file, adapter: adapter)
    let model = SharedExtensionSettingsModel(
      home: home, adapter: adapter, profiles: { [first: "Work", second: "Personal"] })
    let result = try await model.recordApprovedInstall(
      id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", version: "1.2")
    #expect(result.failed == [first, second])
    #expect(model.rows.count == 1)
    #expect(model.rows[0].profiles[first]?.enabled == true)
    #expect(model.rows[0].profiles[second]?.failed == true)
  }
}
