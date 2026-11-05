// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import ShaarEngineABI
import SwiftUI
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
        #"{"schemaVersion":1,"extensions":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"Example","version":"1.2","enabled":\#(enabled),"mayDisable":true,"incognitoEnabled":false,"source":4,"fromWebStore":true}]}"#
          .utf8)
    }
    return Data(#"{"schemaVersion":1,"updated":true}"#.utf8)
  }
}

@Suite("Shared extension Settings")
struct SharedExtensionSettingsTests {
  @Test @MainActor func oneInstallHasIndependentProfileToggles() async throws {
    let first = UUID()
    let second = UUID()
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let transport = SettingsExtensionsTransport(profiles: [first: true, second: false])
    let adapter = ShaarExtensionsAdapter(shaar: transport)
    let home = try ShaarExtensionHome(fileURL: file, adapter: adapter)
    _ = try await home.recordApprovedInstall(
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", approvedVersion: "1.2", profileIDs: [first])
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
    let mutations = calls.filter { call in
      guard call.1 == .manage,
        let args = try? JSONSerialization.jsonObject(with: call.2) as? [String: Any]
      else { return false }
      return args["action"] as? String == "setEnabled"
    }
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
    let adapter = ShaarExtensionsAdapter(shaar: transport)
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

  @Test @MainActor func sharedSectionLaysOutInstalledAndFailedProfiles() async throws {
    let installedProfile = UUID()
    let failedProfile = UUID()
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let transport = SettingsExtensionsTransport(
      profiles: [installedProfile: true], missing: [failedProfile])
    let adapter = ShaarExtensionsAdapter(shaar: transport)
    let home = try ShaarExtensionHome(fileURL: file, adapter: adapter)
    let model = SharedExtensionSettingsModel(
      home: home, adapter: adapter,
      profiles: { [installedProfile: "Work", failedProfile: "Personal"] })
    _ = try await model.recordApprovedInstall(
      id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", version: "1.2")

    let host = NSHostingView(
      rootView: ProfileExtensionsSection(model: nil, sharedModel: model, onAddExtensions: {}))
    host.frame = NSRect(x: 0, y: 0, width: 440, height: 250)
    host.layoutSubtreeIfNeeded()

    #expect(model.rows.first?.profiles[installedProfile]?.enabled == true)
    #expect(model.rows.first?.profiles[failedProfile]?.failed == true)
    #expect(host.fittingSize.width > 0)
    #expect(host.fittingSize.height > 0)
  }
}
