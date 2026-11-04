// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Browser-owned install intents. Chromium still owns each profile's extension
/// instance, update policy, enable flag, and private-window access.
public actor ShaarExtensionHome {
  private struct Catalog: Codable {
    let schemaVersion: Int
    let extensionIDs: [String]
  }

  private let fileURL: URL
  private let adapter: ShaarExtensionsAdapter
  private var ids: Set<String>

  public init(fileURL: URL, adapter: ShaarExtensionsAdapter) throws {
    self.fileURL = fileURL
    self.adapter = adapter
    if FileManager.default.fileExists(atPath: fileURL.path) {
      let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: fileURL))
      guard catalog.schemaVersion == 1,
        catalog.extensionIDs.allSatisfy(Self.validID),
        Set(catalog.extensionIDs).count == catalog.extensionIDs.count
      else { throw ShaarExtensionsAdapterError.invalidResponse("invalid shared extension catalog") }
      ids = Set(catalog.extensionIDs)
    } else {
      ids = []
    }
  }

  public var extensionIDs: [String] { ids.sorted() }

  /// Persist the approved intent before fan-out so a crash or partial failure
  /// can be retried for current and future regular profiles.
  public func recordApprovedInstall(
    _ extensionID: String, profileIDs: [UUID]
  ) async throws -> ShaarSharedInstallResult {
    guard Self.validID(extensionID) else { throw ShaarExtensionsAdapterError.invalidExtensionID }
    let previous = ids
    ids.insert(extensionID)
    do { try save() } catch {
      ids = previous
      throw error
    }
    return await adapter.installAcrossProfiles(extensionID: extensionID, profileIDs: profileIDs)
  }

  /// Call after a regular profile opens and on retry. The native install is
  /// idempotent and must preserve that profile's existing enable state.
  public func reconcile(profileID: UUID) async -> ShaarSharedInstallResult {
    var failed = Set<UUID>()
    for id in ids.sorted() {
      let result = await adapter.installAcrossProfiles(extensionID: id, profileIDs: [profileID])
      failed.formUnion(result.failed)
    }
    let installed: Set<UUID> = failed.isEmpty && !ids.isEmpty ? [profileID] : []
    return ShaarSharedInstallResult(installed: installed, failed: failed)
  }

  private func save() throws {
    let data = try JSONEncoder().encode(Catalog(schemaVersion: 1, extensionIDs: ids.sorted()))
    try data.write(to: fileURL, options: .atomic)
  }

  private static func validID(_ id: String) -> Bool {
    id.utf8.count == 32 && id.utf8.allSatisfy { (97...112).contains(Int($0)) }
  }
}
