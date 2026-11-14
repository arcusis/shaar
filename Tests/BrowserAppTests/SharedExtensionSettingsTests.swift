// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Foundation
import ShaarEngineABI
import SwiftUI
import Testing

@testable import ArcusisBrowser

private actor SettingsExtensionsTransport: ShaarExtensionsTransport {
  var calls: [(UUID, ShaarExtensionsOperation, Data)] = []
  let profiles: [UUID: Bool]
  let missing: Set<UUID>
  let rejectManage: Bool
  let rejectList: Bool

  init(
    profiles: [UUID: Bool], missing: Set<UUID> = [], rejectManage: Bool = false,
    rejectList: Bool = false
  ) {
    self.profiles = profiles
    self.missing = missing
    self.rejectManage = rejectManage
    self.rejectList = rejectList
  }

  func submitExtensions(
    profileID: UUID, operation: ShaarExtensionsOperation, arguments: Data
  ) async throws -> Data {
    calls.append((profileID, operation, arguments))
    if operation == .manage && rejectManage {
      throw NSError(
        domain: "ShaarTestError", code: 42,
        userInfo: [NSLocalizedDescriptionKey: "Raw English engine failure"])
    }
    if operation == .list {
      if rejectList {
        throw NSError(
          domain: "ShaarTestError", code: 42,
          userInfo: [NSLocalizedDescriptionKey: "Raw English engine failure"])
      }
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

private actor DelayedSettingsExtensionsTransport: ShaarExtensionsTransport {
  private var firstListStarted = false
  private var firstListWaiter: CheckedContinuation<Void, Never>?
  private var firstListReply: CheckedContinuation<Data, Never>?
  private var listCount = 0

  func submitExtensions(
    profileID: UUID, operation: ShaarExtensionsOperation, arguments: Data
  ) async throws -> Data {
    guard operation == .list else { return Data(#"{"schemaVersion":1,"updated":true}"#.utf8) }
    listCount += 1
    if listCount == 1 {
      firstListStarted = true
      firstListWaiter?.resume()
      firstListWaiter = nil
      return await withCheckedContinuation { firstListReply = $0 }
    }
    return Self.list(enabled: false)
  }

  func waitForFirstList() async {
    guard !firstListStarted else { return }
    await withCheckedContinuation { firstListWaiter = $0 }
  }

  func releaseFirstList() {
    firstListReply?.resume(returning: Self.list(enabled: true))
    firstListReply = nil
  }

  private static func list(enabled: Bool) -> Data {
    Data(
      #"{"schemaVersion":1,"extensions":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"Example","version":"1.2","enabled":\#(enabled),"mayDisable":true,"incognitoEnabled":false,"source":4,"fromWebStore":true}]}"#
        .utf8)
  }
}

private actor CancelledManageSettingsTransport: ShaarExtensionsTransport {
  func submitExtensions(
    profileID: UUID, operation: ShaarExtensionsOperation, arguments: Data
  ) async throws -> Data {
    if operation == .list {
      return Data(
        #"{"schemaVersion":1,"extensions":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"Example","version":"1.2","enabled":true,"mayDisable":true,"incognitoEnabled":false,"source":4,"fromWebStore":true}]}"#.utf8)
    }
    throw CancellationError()
  }
}

private actor DelayedReconcileExtensionsTransport: ShaarExtensionsTransport {
  private var firstManageStarted = false
  private var firstManageWaiter: CheckedContinuation<Void, Never>?
  private var firstManageReply: CheckedContinuation<Data, Never>?
  private var manageCount = 0

  func submitExtensions(
    profileID: UUID, operation: ShaarExtensionsOperation, arguments: Data
  ) async throws -> Data {
    if operation == .list {
      return Data(#"{"schemaVersion":1,"extensions":[]}"#.utf8)
    }
    manageCount += 1
    if manageCount == 1 {
      firstManageStarted = true
      firstManageWaiter?.resume()
      firstManageWaiter = nil
      return await withCheckedContinuation { firstManageReply = $0 }
    }
    return Data(#"{"schemaVersion":1,"installed":true}"#.utf8)
  }

  func waitForFirstManage() async {
    guard !firstManageStarted else { return }
    await withCheckedContinuation { firstManageWaiter = $0 }
  }

  func releaseFirstAsQueued() {
    firstManageReply?.resume(returning: Data(#"{"schemaVersion":1,"queued":true}"#.utf8))
    firstManageReply = nil
  }
}

@Suite("Shared extension Settings")
struct SharedExtensionSettingsTests {
  @Test @MainActor func staleReconcileCannotReplaceNewerProfileResult() async throws {
    let profileID = UUID()
    let extensionID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data(
      #"{"schemaVersion":2,"intents":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","approvedVersion":"1.2"}]}"#.utf8
    ).write(to: file)
    let transport = DelayedReconcileExtensionsTransport()
    let adapter = ShaarExtensionsAdapter(shaar: transport)
    let home = try ShaarExtensionHome(fileURL: file, adapter: adapter)
    let model = SharedExtensionSettingsModel(
      home: home, adapter: adapter, profiles: { [profileID: "Work"] })
    await model.reload()

    let older = Task { await model.reconcile(profileID: profileID) }
    await transport.waitForFirstManage()
    await model.reconcile(profileID: profileID)
    #expect(model.rows.first?.profiles[profileID]?.pending == false)

    await transport.releaseFirstAsQueued()
    await older.value
    #expect(model.rows.first?.id == extensionID)
    #expect(model.rows.first?.profiles[profileID]?.pending == false)
    #expect(model.rows.first?.profiles[profileID]?.failed == false)
  }

  @Test @MainActor func olderExtensionReloadCannotReplaceNewerState() async throws {
    let profileID = UUID()
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data(
      #"{"schemaVersion":2,"intents":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","approvedVersion":"1.2"}]}"#
        .utf8
    ).write(to: file)
    let transport = DelayedSettingsExtensionsTransport()
    let adapter = ShaarExtensionsAdapter(shaar: transport)
    let home = try ShaarExtensionHome(fileURL: file, adapter: adapter)
    let model = SharedExtensionSettingsModel(
      home: home, adapter: adapter, profiles: { [profileID: "Work"] })

    let olderReload = Task { await model.reload() }
    await transport.waitForFirstList()
    await model.reload()
    #expect(model.rows.first?.profiles[profileID]?.enabled == false)

    await transport.releaseFirstList()
    await olderReload.value
    #expect(model.rows.first?.profiles[profileID]?.enabled == false)
  }

  @Test @MainActor func failedToggleShowsLocalizedActionableError() async throws {
    let profileID = UUID()
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let transport = SettingsExtensionsTransport(
      profiles: [profileID: true], rejectManage: true)
    let adapter = ShaarExtensionsAdapter(shaar: transport)
    let home = try ShaarExtensionHome(fileURL: file, adapter: adapter)
    _ = try await home.recordApprovedInstall(
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", approvedVersion: "1.2", profileIDs: [profileID])
    let model = SharedExtensionSettingsModel(
      home: home, adapter: adapter, profiles: { [profileID: "Work"] })
    await model.reload()
    let row = try #require(model.rows.first)

    await model.setEnabled(false, extensionID: row.id, profileID: profileID)
    #expect(model.rows.first?.profiles[profileID]?.enabled == true)
    #expect(model.error == SettingsL10n.string("Could not update the extension. Try again."))
  }

  @Test @MainActor func cancelledToggleDoesNotShowFailure() async throws {
    let profileID = UUID()
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data(
      #"{"schemaVersion":2,"intents":[{"id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","approvedVersion":"1.2"}]}"#.utf8
    ).write(to: file)
    let transport = CancelledManageSettingsTransport()
    let adapter = ShaarExtensionsAdapter(shaar: transport)
    let home = try ShaarExtensionHome(fileURL: file, adapter: adapter)
    let model = SharedExtensionSettingsModel(
      home: home, adapter: adapter, profiles: { [profileID: "Work"] })
    await model.reload()
    let row = try #require(model.rows.first)

    let toggle = Task { @MainActor in
      await model.setEnabled(false, extensionID: row.id, profileID: profileID)
    }
    toggle.cancel()
    await toggle.value

    #expect(model.error == nil)
  }

  @Test @MainActor func listFailureExplainsWhyExtensionsAreMissing() async throws {
    let profileID = UUID()
    let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let transport = SettingsExtensionsTransport(profiles: [:], rejectList: true)
    let adapter = ShaarExtensionsAdapter(shaar: transport)
    let home = try ShaarExtensionHome(fileURL: file, adapter: adapter)
    let model = SharedExtensionSettingsModel(
      home: home, adapter: adapter, profiles: { [profileID: "Work"] })

    await model.reload()
    #expect(model.rows.isEmpty)
    #expect(model.error == SettingsL10n.string("Could not load extensions. Try again."))
  }

  @Test @MainActor func extensionNamesFollowTheSelectedLanguageOrder() {
    let rows = [
      SharedExtensionSettingsRow(id: "english", name: "A", version: "1", profiles: [:]),
      SharedExtensionSettingsRow(id: "hebrew", name: "אב", version: "1", profiles: [:]),
    ]
    #expect(
      SharedExtensionSettingsModel.sortedRows(rows, language: .hebrew).map(\.id)
        == ["hebrew", "english"])
    #expect(
      SharedExtensionSettingsModel.sortedRows(rows, language: .english).map(\.id)
        == ["english", "hebrew"])
  }

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
