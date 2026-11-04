// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Browser-owned install intents. Chromium still owns each profile's extension
/// instance, update policy, enable flag, and private-window access.
public actor ShaarExtensionHome {
  private struct Catalog: Codable {
    let schemaVersion: Int
    let intents: [Intent]
  }

  private struct Intent: Codable {
    let id: String
    let approvedVersion: String
  }

  private let fileURL: URL
  private let adapter: ShaarExtensionsAdapter
  private var versions: [String: String]

  public init(fileURL: URL, adapter: ShaarExtensionsAdapter) throws {
    self.fileURL = fileURL
    self.adapter = adapter
    if FileManager.default.fileExists(atPath: fileURL.path) {
      let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: fileURL))
      guard catalog.schemaVersion == 2,
        catalog.intents.allSatisfy({
          Self.validID($0.id) && ShaarExtensionsAdapter.isValidVersion($0.approvedVersion)
        }),
        Set(catalog.intents.map(\.id)).count == catalog.intents.count
      else { throw ShaarExtensionsAdapterError.invalidResponse("invalid shared extension catalog") }
      versions = Dictionary(
        uniqueKeysWithValues: catalog.intents.map { ($0.id, $0.approvedVersion) })
    } else {
      versions = [:]
    }
  }

  public var extensionIDs: [String] { versions.keys.sorted() }

  /// Persist the approved intent before fan-out so a crash or partial failure
  /// can be retried for current and future regular profiles.
  public func recordApprovedInstall(
    _ extensionID: String, approvedVersion: String, profileIDs: [UUID]
  ) async throws -> ShaarSharedInstallResult {
    guard Self.validID(extensionID) else { throw ShaarExtensionsAdapterError.invalidExtensionID }
    guard ShaarExtensionsAdapter.isValidVersion(approvedVersion) else {
      throw ShaarExtensionsAdapterError.invalidApprovedVersion
    }
    var confirmed = false
    for profileID in Set(profileIDs) {
      guard let installed = try? await adapter.list(profileID: profileID) else { continue }
      if installed.contains(where: {
        $0.id == extensionID && $0.version == approvedVersion && $0.fromWebStore
      }) {
        confirmed = true
        break
      }
    }
    guard confirmed else { throw ShaarExtensionsAdapterError.installNotConfirmed }
    let previous = versions
    versions[extensionID] = approvedVersion
    do { try save() } catch {
      versions = previous
      throw error
    }
    return await adapter.installAcrossProfiles(
      extensionID: extensionID, approvedVersion: approvedVersion, profileIDs: profileIDs)
  }

  /// Call after a regular profile opens and on retry. The native install is
  /// idempotent and must preserve that profile's existing enable state.
  public func reconcile(profileID: UUID) async -> ShaarSharedInstallResult {
    var failed = Set<UUID>()
    var pending = Set<UUID>()
    for result in await reconcileDetails(profileID: profileID).values {
      failed.formUnion(result.failed)
      pending.formUnion(result.pending)
    }
    let installed: Set<UUID> =
      failed.isEmpty && pending.isEmpty && !versions.isEmpty
      ? [profileID] : []
    return ShaarSharedInstallResult(installed: installed, failed: failed, pending: pending)
  }

  public func reconcileDetails(profileID: UUID) async -> [String: ShaarSharedInstallResult] {
    var details: [String: ShaarSharedInstallResult] = [:]
    for (id, approvedVersion) in versions.sorted(by: { $0.key < $1.key }) {
      let result = await adapter.installAcrossProfiles(
        extensionID: id, approvedVersion: approvedVersion, profileIDs: [profileID])
      details[id] = result
    }
    return details
  }

  private func save() throws {
    let intents = versions.sorted { $0.key < $1.key }.map {
      Intent(id: $0.key, approvedVersion: $0.value)
    }
    let data = try JSONEncoder().encode(Catalog(schemaVersion: 2, intents: intents))
    try data.write(to: fileURL, options: .atomic)
  }

  private static func validID(_ id: String) -> Bool {
    id.utf8.count == 32 && id.utf8.allSatisfy { (97...112).contains(Int($0)) }
  }
}
