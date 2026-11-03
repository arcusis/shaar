// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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

  public init(
    id: String, name: String, version: String, enabled: Bool,
    mayDisable: Bool, incognitoEnabled: Bool, source: Int
  ) {
    self.id = id
    self.name = name
    self.version = version
    self.enabled = enabled
    self.mayDisable = mayDisable
    self.incognitoEnabled = incognitoEnabled
    self.source = source
  }
}

public enum ShaarExtensionManagementAction: Sendable, Equatable {
  case setEnabled(String, Bool)
  case setIncognitoEnabled(String, Bool)
  case uninstall(String)
  case install(String, source: ShaarExtensionInstallSource)

  fileprivate var fields: [String: Any] {
    switch self {
    case .setEnabled(let id, let enabled):
      return ["action": "setEnabled", "extensionId": id, "enabled": enabled]
    case .setIncognitoEnabled(let id, let enabled):
      return ["action": "setIncognitoEnabled", "extensionId": id, "enabled": enabled]
    case .uninstall(let id):
      return ["action": "uninstall", "extensionId": id]
    case .install(let id, let source):
      return ["action": "install", "extensionId": id, "source": source.rawValue]
    }
  }

  fileprivate var responseKey: String {
    if case .uninstall = self { return "removed" }
    if case .install = self { return "accepted" }
    return "updated"
  }
}

public enum ShaarExtensionInstallSource: String, Sendable, Equatable {
  case webStore, unpacked
}

public enum ShaarExtensionActionRoute: String, Sendable, Equatable {
  case none, popup, sidePanel
}

public struct ShaarExtensionConsentRequest: Sendable, Equatable, Identifiable {
  public let id: String
  public let profileID: UUID
  public let windowID: UUID?
  public let tabID: UUID?
  public let extensionID: String
  public let name: String
  public let version: String
  public let source: ShaarExtensionInstallSource
  public let sourceURL: String
  public let permissions: [String]
  public let hostPermissions: [String]
  public let permissionsComplete: Bool
  public let deadline: Date
}

public enum ShaarExtensionsEvent: Sendable, Equatable {
  case changed(profileID: UUID, kind: String, extensionID: String)
  case consentRequested(ShaarExtensionConsentRequest)
  case popupOpened(profileID: UUID, windowID: UUID, tabID: UUID, popupID: String,
    extensionID: String)
  case popupClosed(profileID: UUID, windowID: UUID, popupID: String)
  case popupSizeChanged(profileID: UUID, windowID: UUID, popupID: String, width: Double,
    height: Double)
}

/// Transport for the single `shaar_submit` entry point. The bridge copies result
/// bytes before returning from the C callback and binds the request to this profile.
public protocol ShaarExtensionsTransport: Sendable {
  func submitExtensions(
    profileID: UUID, windowID: UUID?, tabID: UUID?, operation: ShaarExtensionsOperation,
    arguments: Data
  ) async throws -> Data
}

/// Existing Ardia implementation remains the shipping default until migration gates pass.
public protocol ArdiaExtensionsBackend: Sendable {
  func list(profileID: UUID) async throws -> [ShaarExtensionSummary]
  func manage(profileID: UUID, action: ShaarExtensionManagementAction) async throws
}

public enum ShaarExtensionsAdapterError: Error, Equatable, Sendable {
  case invalidResponse(String)
  case invalidExtensionID
  case mutationNotConfirmed
}

public struct ShaarExtensionsAdapter: Sendable {
  private let implementation: ShaarEngineImplementation
  private let ardia: any ArdiaExtensionsBackend
  private let shaar: any ShaarExtensionsTransport

  public init(
    implementation: ShaarEngineImplementation = .shippingDefault,
    ardia: any ArdiaExtensionsBackend,
    shaar: any ShaarExtensionsTransport
  ) {
    self.implementation = implementation
    self.ardia = ardia
    self.shaar = shaar
  }

  public func list(profileID: UUID) async throws -> [ShaarExtensionSummary] {
    guard implementation == .shaar else { return try await ardia.list(profileID: profileID) }
    let data = try await shaar.submitExtensions(
      profileID: profileID, windowID: nil, tabID: nil, operation: .list,
      arguments: try encode(["schemaVersion": 1]))
    let root = try object(data, required: ["schemaVersion", "extensions"])
    try requireVersion(root)
    guard let rows = root["extensions"] as? [[String: Any]], rows.count <= 10_000 else {
      throw ShaarExtensionsAdapterError.invalidResponse("invalid extension list")
    }
    var ids = Set<String>()
    return try rows.map { row in
      guard
        Set(row.keys)
          == Set([
            "id", "name", "version", "enabled", "mayDisable", "incognitoEnabled", "source",
          ]),
        let id = row["id"] as? String, Self.isValidExtensionID(id), ids.insert(id).inserted,
        let name = row["name"] as? String, name.utf8.count <= 4096,
        let version = row["version"] as? String, version.utf8.count <= 256,
        let enabled = row["enabled"] as? Bool,
        let mayDisable = row["mayDisable"] as? Bool,
        let incognitoEnabled = row["incognitoEnabled"] as? Bool,
        let source = row["source"] as? Int
      else { throw ShaarExtensionsAdapterError.invalidResponse("malformed extension row") }
      return ShaarExtensionSummary(
        id: id, name: name, version: version, enabled: enabled,
        mayDisable: mayDisable, incognitoEnabled: incognitoEnabled, source: source)
    }
  }

  public func manage(profileID: UUID, action: ShaarExtensionManagementAction) async throws {
    guard implementation == .shaar else {
      try await ardia.manage(profileID: profileID, action: action)
      return
    }
    let fields = action.fields
    guard let id = fields["extensionId"] as? String, Self.isValidExtensionID(id) else {
      throw ShaarExtensionsAdapterError.invalidExtensionID
    }
    var envelope = fields
    envelope["schemaVersion"] = 1
    let data = try await shaar.submitExtensions(
      profileID: profileID, windowID: nil, tabID: nil, operation: .manage,
      arguments: try encode(envelope))
    let resultKey = action.responseKey
    let root = try object(data, required: ["schemaVersion", resultKey])
    try requireVersion(root)
    guard root[resultKey] as? Bool == true else {
      throw ShaarExtensionsAdapterError.mutationNotConfirmed
    }
  }

  public func invoke(
    profileID: UUID, windowID: UUID, tabID: UUID, extensionID: String
  ) async throws -> ShaarExtensionActionRoute {
    guard Self.isValidExtensionID(extensionID) else {
      throw ShaarExtensionsAdapterError.invalidExtensionID
    }
    let data = try await shaar.submitExtensions(
      profileID: profileID, windowID: windowID, tabID: tabID, operation: .action,
      arguments: try encode([
        "schemaVersion": 1, "action": "invoke", "extensionId": extensionID,
      ]))
    let root = try object(data, required: ["schemaVersion", "route"])
    try requireVersion(root)
    guard let rawRoute = root["route"] as? String,
      let route = ShaarExtensionActionRoute(rawValue: rawRoute)
    else { throw ShaarExtensionsAdapterError.invalidResponse("invalid action route") }
    return route
  }

  public func resolveInstallDecision(
    profileID: UUID, requestID: String, accepted: Bool
  ) async throws {
    guard !requestID.isEmpty, requestID.utf8.count <= 256 else {
      throw ShaarExtensionsAdapterError.invalidResponse("invalid consent request ID")
    }
    let data = try await shaar.submitExtensions(
      profileID: profileID, windowID: nil, tabID: nil, operation: .installDecision,
      arguments: try encode([
        "schemaVersion": 1, "consentRequestId": requestID, "accepted": accepted,
      ]))
    let root = try object(data, required: ["schemaVersion", "resolved"])
    try requireVersion(root)
    guard root["resolved"] as? Bool == true else {
      throw ShaarExtensionsAdapterError.mutationNotConfirmed
    }
  }

  public func closePopup(profileID: UUID, windowID: UUID, popupID: String) async throws {
    guard !popupID.isEmpty, popupID.utf8.count <= 256 else {
      throw ShaarExtensionsAdapterError.invalidResponse("invalid popup ID")
    }
    let data = try await shaar.submitExtensions(
      profileID: profileID, windowID: windowID, tabID: nil, operation: .popupClose,
      arguments: try encode(["schemaVersion": 1, "popupId": popupID]))
    let root = try object(data, required: ["schemaVersion", "closed"])
    try requireVersion(root)
    guard root["closed"] as? Bool == true else {
      throw ShaarExtensionsAdapterError.mutationNotConfirmed
    }
  }

  public static func decodeEvent(_ event: ShaarCopiedEvent) throws -> ShaarExtensionsEvent {
    guard event.kind == 13,
      event.sessionID.isEmpty,
      let profileText = String(data: event.profileID, encoding: .utf8),
      let profileID = UUID(uuidString: profileText),
      let payload = try JSONSerialization.jsonObject(with: event.payloadJSON) as? [String: Any],
      payload["schemaVersion"] as? Int == 1,
      let kind = payload["kind"] as? String
    else { throw ShaarExtensionsAdapterError.invalidResponse("invalid extension event") }
    switch kind {
    case "extension.enabledChanged", "extension.incognitoVisibilityChanged",
      "extension.removed", "extension.installed", "extension.updated",
      "extension.installProgress", "extension.installCompleted", "extension.installFailed":
      guard let extensionID = payload["extensionId"] as? String,
        Self.isValidExtensionID(extensionID)
      else { throw ShaarExtensionsAdapterError.invalidResponse("invalid extension event ID") }
      return .changed(profileID: profileID, kind: kind, extensionID: extensionID)
    case "extension.installConsentRequested":
      guard let id = payload["requestId"] as? String, !id.isEmpty,
        let extensionID = payload["extensionId"] as? String,
        Self.isValidExtensionID(extensionID), let name = payload["name"] as? String,
        let version = payload["version"] as? String,
        let rawSource = payload["source"] as? String,
        let source = ShaarExtensionInstallSource(rawValue: rawSource),
        let sourceURL = payload["sourceUrl"] as? String,
        let permissions = payload["permissions"] as? [String],
        let hostPermissions = payload["hostPermissions"] as? [String],
        let permissionsComplete = payload["permissionsComplete"] as? Bool,
        let deadline = payload["deadline"] as? TimeInterval
      else { throw ShaarExtensionsAdapterError.invalidResponse("invalid consent event") }
      let windowID = (payload["windowId"] as? String).flatMap(UUID.init(uuidString:))
      let tabID = (payload["tabId"] as? String).flatMap(UUID.init(uuidString:))
      guard windowID != nil, tabID != nil,
        windowID == UUID(data: event.windowID), tabID == UUID(data: event.tabID)
      else {
        throw ShaarExtensionsAdapterError.invalidResponse("consent event lacks owner")
      }
      return .consentRequested(.init(
        id: id, profileID: profileID, windowID: windowID, tabID: tabID,
        extensionID: extensionID, name: name, version: version, source: source,
        sourceURL: sourceURL, permissions: permissions, hostPermissions: hostPermissions,
        permissionsComplete: permissionsComplete,
        deadline: Date(timeIntervalSince1970: deadline)))
    case "extension.actionPopupOpened":
      guard let window = (payload["windowId"] as? String).flatMap(UUID.init(uuidString:)),
        let tab = (payload["tabId"] as? String).flatMap(UUID.init(uuidString:)),
        window == UUID(data: event.windowID), tab == UUID(data: event.tabID),
        let id = payload["popupId"] as? String, !id.isEmpty,
        let extensionID = payload["extensionId"] as? String,
        Self.isValidExtensionID(extensionID)
      else { throw ShaarExtensionsAdapterError.invalidResponse("invalid popup event") }
      return .popupOpened(profileID: profileID, windowID: window, tabID: tab,
        popupID: id, extensionID: extensionID)
    case "extension.actionPopupClosed":
      guard let window = (payload["windowId"] as? String).flatMap(UUID.init(uuidString:)),
        window == UUID(data: event.windowID),
        let id = payload["popupId"] as? String, !id.isEmpty
      else { throw ShaarExtensionsAdapterError.invalidResponse("invalid popup close event") }
      return .popupClosed(profileID: profileID, windowID: window, popupID: id)
    case "extension.actionPopupSizeChanged":
      guard let window = (payload["windowId"] as? String).flatMap(UUID.init(uuidString:)),
        window == UUID(data: event.windowID),
        let id = payload["popupId"] as? String, !id.isEmpty,
        let width = payload["width"] as? Double, width.isFinite,
        let height = payload["height"] as? Double, height.isFinite,
        (100...1200).contains(width), (100...1200).contains(height)
      else { throw ShaarExtensionsAdapterError.invalidResponse("invalid popup size event") }
      return .popupSizeChanged(
        profileID: profileID, windowID: window, popupID: id, width: width, height: height)
    default:
      throw ShaarExtensionsAdapterError.invalidResponse("unknown extension event")
    }
  }

  private func object(_ data: Data, required: Set<String>) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(value.keys) == required
    else { throw ShaarExtensionsAdapterError.invalidResponse("invalid response object") }
    return value
  }

  private func requireVersion(_ root: [String: Any]) throws {
    guard root["schemaVersion"] as? Int == 1 else {
      throw ShaarExtensionsAdapterError.invalidResponse("unsupported schema version")
    }
  }

  private func encode(_ object: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  private static func isValidExtensionID(_ id: String) -> Bool {
    id.utf8.count == 32 && id.utf8.allSatisfy { (97...112).contains(Int($0)) }
  }
}

private extension UUID {
  init?(data: Data) {
    guard let value = String(data: data, encoding: .utf8) else { return nil }
    self.init(uuidString: value)
  }
}
