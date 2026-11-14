// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import CoreFoundation
import Foundation

public enum ShaarExtensionsOperation: UInt32, Sendable {
  case list = 800
  case manage = 801
  case action = 802
  case installDecision = 803
  case popupClose = 804
}

public struct ShaarExtensionSummary: Equatable, Sendable, Identifiable {
  public let id: String
  public let name: String
  public let version: String
  public let enabled: Bool
  public let mayDisable: Bool
  public let incognitoEnabled: Bool
  public let source: Int
  public let fromWebStore: Bool

  public init(
    id: String, name: String, version: String, enabled: Bool,
    mayDisable: Bool, incognitoEnabled: Bool, source: Int, fromWebStore: Bool = false
  ) {
    self.id = id
    self.name = name
    self.version = version
    self.enabled = enabled
    self.mayDisable = mayDisable
    self.incognitoEnabled = incognitoEnabled
    self.source = source
    self.fromWebStore = fromWebStore
  }
}

public enum ShaarExtensionManagementAction: Sendable, Equatable {
  case setEnabled(String, Bool)
  case uninstall(String)

  fileprivate var fields: [String: Any] {
    switch self {
    case .setEnabled(let id, let enabled):
      return ["action": "setEnabled", "extensionId": id, "enabled": enabled]
    case .uninstall(let id):
      return ["action": "uninstall", "extensionId": id]
    }
  }

  fileprivate var responseKey: String {
    if case .uninstall = self { return "removed" }
    return "updated"
  }
}

/// Transport for the single `shaar_submit` entry point. The bridge copies result
/// bytes before returning from the C callback and binds the request to this profile.
public protocol ShaarExtensionsTransport: Sendable {
  func submitExtensions(
    profileID: UUID, operation: ShaarExtensionsOperation, arguments: Data
  ) async throws -> Data
}

public enum ShaarExtensionsAdapterError: Error, Equatable, Sendable {
  case invalidResponse(String)
  case invalidExtensionID
  case invalidApprovedVersion
  case installNotConfirmed
  case mutationNotConfirmed
}

public struct ShaarSharedInstallResult: Equatable, Sendable {
  public let installed: Set<UUID>
  public let failed: Set<UUID>
  public let pending: Set<UUID>

  public var complete: Bool { failed.isEmpty && pending.isEmpty }
}

public struct ShaarExtensionsAdapter: Sendable {
  private let shaar: any ShaarExtensionsTransport

  public init(shaar: any ShaarExtensionsTransport) {
    self.shaar = shaar
  }

  public func list(profileID: UUID) async throws -> [ShaarExtensionSummary] {
    let data = try await shaar.submitExtensions(
      profileID: profileID, operation: .list,
      arguments: try encode(["schemaVersion": 1]))
    let root = try object(data, required: ["schemaVersion", "extensions"])
    try requireVersion(root)
    guard let rows = root["extensions"] as? [[String: Any]], rows.count <= 10_000 else {
      throw ShaarExtensionsAdapterError.invalidResponse("invalid extension list")
    }
    var ids = Set<String>()
    return try rows.map { row in
      let required: Set<String> = [
        "id", "name", "version", "enabled", "mayDisable", "incognitoEnabled", "source",
      ]
      let metadata: Set<String> = [
        "description", "permissions", "hostPermissions", "fromWebStore",
      ]
      guard
        required.isSubset(of: Set(row.keys)),
        Set(row.keys).isSubset(of: required.union(metadata)),
        let id = row["id"] as? String, Self.isValidExtensionID(id), ids.insert(id).inserted,
        let name = row["name"] as? String, name.utf8.count <= 4096,
        let version = row["version"] as? String, version.utf8.count <= 256,
        Self.isJSONBoolean(row["enabled"]),
        let enabled = row["enabled"] as? Bool,
        Self.isJSONBoolean(row["mayDisable"]),
        let mayDisable = row["mayDisable"] as? Bool,
        Self.isJSONBoolean(row["incognitoEnabled"]),
        let incognitoEnabled = row["incognitoEnabled"] as? Bool,
        !Self.isJSONBoolean(row["source"]),
        let source = row["source"] as? Int,
        row["description"] == nil || row["description"] is String,
        row["permissions"] == nil || row["permissions"] is [String],
        row["hostPermissions"] == nil || row["hostPermissions"] is [String],
        row["fromWebStore"] == nil || Self.isJSONBoolean(row["fromWebStore"])
      else { throw ShaarExtensionsAdapterError.invalidResponse("malformed extension row") }
      return ShaarExtensionSummary(
        id: id, name: name, version: version, enabled: enabled,
        mayDisable: mayDisable, incognitoEnabled: incognitoEnabled, source: source,
        fromWebStore: row["fromWebStore"] as? Bool ?? false)
    }
  }

  public func manage(profileID: UUID, action: ShaarExtensionManagementAction) async throws {
    let fields = action.fields
    guard let id = fields["extensionId"] as? String, Self.isValidExtensionID(id) else {
      throw ShaarExtensionsAdapterError.invalidExtensionID
    }
    var envelope = fields
    envelope["schemaVersion"] = 1
    let data = try await shaar.submitExtensions(
      profileID: profileID, operation: .manage, arguments: try encode(envelope))
    let resultKey = action.responseKey
    let root = try object(data, required: ["schemaVersion", resultKey])
    try requireVersion(root)
    guard Self.isJSONBoolean(root[resultKey]), root[resultKey] as? Bool == true else {
      throw ShaarExtensionsAdapterError.mutationNotConfirmed
    }
  }

  /// Apply one approved shared-home intent to regular profiles. Keep every
  /// outcome so a failed profile can be retried without repeating consent.
  public func installAcrossProfiles(
    extensionID: String, approvedVersion: String, profileIDs: [UUID]
  ) async -> ShaarSharedInstallResult {
    let targets = Array(Set(profileIDs)).sorted { $0.uuidString < $1.uuidString }
    guard Self.isValidExtensionID(extensionID), Self.isValidVersion(approvedVersion) else {
      return ShaarSharedInstallResult(installed: [], failed: Set(targets), pending: [])
    }
    var installed = Set<UUID>()
    var failed = Set<UUID>()
    var pending = Set<UUID>()
    for profileID in targets {
      do {
        let arguments = try encode([
          "schemaVersion": 1, "action": "install", "extensionId": extensionID,
          "source": "sharedHome", "approvedVersion": approvedVersion,
        ])
        let data = try await shaar.submitExtensions(
          profileID: profileID, operation: .manage, arguments: arguments)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let root,
          Set(root.keys) == ["schemaVersion", "installed"]
            || Set(root.keys) == ["schemaVersion", "queued"]
        else { throw ShaarExtensionsAdapterError.invalidResponse("invalid install result") }
        try requireVersion(root)
        if Self.isJSONBoolean(root["installed"]), root["installed"] as? Bool == true {
          installed.insert(profileID)
        } else if Self.isJSONBoolean(root["queued"]), root["queued"] as? Bool == true {
          pending.insert(profileID)
        } else {
          failed.insert(profileID)
        }
      } catch {
        failed.insert(profileID)
      }
    }
    return ShaarSharedInstallResult(installed: installed, failed: failed, pending: pending)
  }

  private func object(_ data: Data, required: Set<String>) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(value.keys) == required
    else { throw ShaarExtensionsAdapterError.invalidResponse("invalid response object") }
    return value
  }

  private func requireVersion(_ root: [String: Any]) throws {
    guard !Self.isJSONBoolean(root["schemaVersion"]),
      let version = root["schemaVersion"] as? NSNumber,
      Int(exactly: version.doubleValue) == 1
    else {
      throw ShaarExtensionsAdapterError.invalidResponse("unsupported schema version")
    }
  }

  private func encode(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  private static func isValidExtensionID(_ id: String) -> Bool {
    id.utf8.count == 32 && id.utf8.allSatisfy { (97...112).contains(Int($0)) }
  }

  private static func isJSONBoolean(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
  }

  static func isValidVersion(_ version: String) -> Bool {
    !version.isEmpty && version.utf8.count <= 64
      && version.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
        !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains(Int($0)) }
      }
  }
}
