// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Observation
import ShaarEngineABI

struct SharedExtensionProfileState: Equatable {
  let name: String
  let enabled: Bool?
  let pending: Bool
  let failed: Bool
}

struct SharedExtensionSettingsRow: Identifiable, Equatable {
  let id: String
  let name: String
  let version: String
  let profiles: [UUID: SharedExtensionProfileState]
}

/// One catalog row per extension, with each profile's native enable state.
@MainActor @Observable
final class SharedExtensionSettingsModel {
  private let home: ShaarExtensionHome
  private let adapter: ShaarExtensionsAdapter
  private let profileNames: @MainActor () -> [UUID: String]
  private var pending: [String: Set<UUID>] = [:]
  private var failed: [String: Set<UUID>] = [:]
  private var reloadID = UUID()
  private var reconcileIDs: [UUID: UUID] = [:]
  private(set) var rows: [SharedExtensionSettingsRow] = []
  private(set) var error: String?

  init(
    home: ShaarExtensionHome, adapter: ShaarExtensionsAdapter,
    profiles: @escaping @MainActor () -> [UUID: String]
  ) {
    self.home = home
    self.adapter = adapter
    self.profileNames = profiles
  }

  static func sortedRows(
    _ rows: [SharedExtensionSettingsRow], language: BrowserLanguage = .currentLaunchLanguage
  ) -> [SharedExtensionSettingsRow] {
    let locale = Locale(identifier: language.localeIdentifier)
    return rows.sorted { lhs, rhs in
      let order = lhs.name.compare(
        rhs.name, options: [.caseInsensitive, .diacriticInsensitive, .numeric], locale: locale)
      return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }
  }

  func reload() async {
    let request = UUID()
    reloadID = request
    let names = profileNames()
    let ids = await home.extensionIDs
    guard reloadID == request, !Task.isCancelled else { return }
    error = nil
    var installed: [UUID: [String: ShaarExtensionSummary]] = [:]
    for profileID in names.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
      do {
        let list = try await adapter.list(profileID: profileID)
        guard reloadID == request, !Task.isCancelled else { return }
        installed[profileID] = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
      } catch {
        guard reloadID == request, !Task.isCancelled else { return }
        self.error = SettingsL10n.string("Could not load extensions. Try again.")
      }
    }
    guard reloadID == request, !Task.isCancelled else { return }
    rows = Self.sortedRows(
      ids.map { id in
        let known = installed.values.compactMap { $0[id] }.first
        let states = names.mapValues { name in
          SharedExtensionProfileState(name: name, enabled: nil, pending: false, failed: false)
        }
        var profiles = states
        for profileID in names.keys {
          if let item = installed[profileID]?[id] {
            profiles[profileID] = SharedExtensionProfileState(
              name: names[profileID] ?? "", enabled: item.enabled, pending: false, failed: false)
            pending[id]?.remove(profileID)
            failed[id]?.remove(profileID)
          } else if pending[id]?.contains(profileID) == true {
            profiles[profileID] = SharedExtensionProfileState(
              name: names[profileID] ?? "", enabled: nil, pending: true, failed: false)
          } else if failed[id]?.contains(profileID) == true {
            profiles[profileID] = SharedExtensionProfileState(
              name: names[profileID] ?? "", enabled: nil, pending: false, failed: true)
          }
        }
        return SharedExtensionSettingsRow(
          id: id, name: known?.name ?? id, version: known?.version ?? "", profiles: profiles)
      })
  }

  func recordApprovedInstall(id: String, version: String) async throws -> ShaarSharedInstallResult {
    let result = try await home.recordApprovedInstall(
      id, approvedVersion: version, profileIDs: Array(profileNames().keys))
    pending[id] = result.pending
    failed[id] = result.failed
    await reload()
    return result
  }

  func reconcile(profileID: UUID) async {
    let request = UUID()
    reconcileIDs[profileID] = request
    let details = await home.reconcileDetails(profileID: profileID)
    guard reconcileIDs[profileID] == request, !Task.isCancelled else { return }
    for (id, result) in details {
      pending[id, default: []].subtract([profileID])
      failed[id, default: []].subtract([profileID])
      pending[id, default: []].formUnion(result.pending)
      failed[id, default: []].formUnion(result.failed)
    }
    await reload()
  }

  func setEnabled(_ enabled: Bool, extensionID: String, profileID: UUID) async {
    guard rows.first(where: { $0.id == extensionID })?.profiles[profileID]?.enabled != nil else {
      return
    }
    do {
      try await adapter.manage(
        profileID: profileID, action: .setEnabled(extensionID, enabled))
      error = nil
      await reload()
    } catch is CancellationError {
      return
    } catch {
      self.error = SettingsL10n.string("Could not update the extension. Try again.")
    }
  }
}
