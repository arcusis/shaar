// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public enum ShaarSiteDataOperation: UInt32, Sendable {
  case settingsGet = 700
  case settingsSet = 701
  case settingsReset = 702
  case settingsOrigins = 703
  case siteDataClear = 704
  case browsingDataClear = 705
  case siteCookiesClear = 706
  case thirdPartyCookiesGet = 707
  case thirdPartyCookiesSet = 708
}

public enum ShaarSiteSettingValue: String, Codable, Sendable {
  case allow, block, ask, `default`
}

public struct ShaarSiteSetting: Equatable, Sendable {
  public let value: ShaarSiteSettingValue
  public let isDefault: Bool
  public init(value: ShaarSiteSettingValue, isDefault: Bool) {
    self.value = value
    self.isDefault = isDefault
  }
}

public struct ShaarThirdPartyCookiePolicy: Equatable, Sendable {
  public let blocked: Bool
  public let managed: Bool
  public init(blocked: Bool, managed: Bool) {
    self.blocked = blocked
    self.managed = managed
  }
}

public enum ShaarSiteDataError: Error, Equatable, Sendable {
  case malformedResponse
  case invalidOrigin
  case unsupportedCapability
  case wrongProfile
}

public protocol ShaarSiteDataTransport: Sendable {
  func submit(profileID: UUID, operation: ShaarSiteDataOperation, arguments: Data) async throws
    -> Data
}

/// Typed site-data calls over the Shaar ABI. The application keeps its Ardia
/// route unless the existing implementation choice selects `.shaar`.
public struct ShaarSiteDataAdapter: Sendable {
  private let transport: any ShaarSiteDataTransport
  public let profileID: UUID
  public let implementation: ShaarEngineImplementation

  public init(
    profileID: UUID,
    implementation: ShaarEngineImplementation = .shippingDefault,
    transport: any ShaarSiteDataTransport
  ) {
    self.profileID = profileID
    self.implementation = implementation
    self.transport = transport
  }

  public static func selected(
    profileID: UUID,
    implementation: ShaarEngineImplementation,
    transport: any ShaarSiteDataTransport
  ) -> Self? {
    guard implementation == .shaar else { return nil }
    return Self(profileID: profileID, implementation: implementation, transport: transport)
  }

  public func settings(origin: String) async throws -> [String: ShaarSiteSetting] {
    let root = try await submit(.settingsGet, ["origin": try Self.canonicalOrigin(origin)])
    guard let values = root["settings"] as? [String: [String: Any]],
      values.keys.allSatisfy({ Self.settingNames.contains($0) })
    else { throw ShaarSiteDataError.malformedResponse }
    var result: [String: ShaarSiteSetting] = [:]
    for (name, value) in values {
      guard let raw = value["value"] as? String,
        let setting = ShaarSiteSettingValue(rawValue: raw),
        let isDefault = value["isDefault"] as? Bool,
        Set(value.keys) == ["value", "isDefault"]
      else { throw ShaarSiteDataError.malformedResponse }
      result[name] = ShaarSiteSetting(value: setting, isDefault: isDefault)
    }
    return result
  }

  public func set(origin: String, type: String, value: ShaarSiteSettingValue) async throws
    -> ShaarSiteSetting
  {
    guard Self.settingNames.contains(type) else { throw ShaarSiteDataError.malformedResponse }
    let root = try await submit(
      .settingsSet,
      [
        "origin": try Self.canonicalOrigin(origin), "type": type, "value": value.rawValue,
      ])
    guard Set(root.keys) == ["schemaVersion", "value", "isDefault"],
      let raw = root["value"] as? String, let setting = ShaarSiteSettingValue(rawValue: raw),
      let isDefault = root["isDefault"] as? Bool
    else { throw ShaarSiteDataError.malformedResponse }
    return ShaarSiteSetting(value: setting, isDefault: isDefault)
  }

  public func reset(origin: String) async throws -> Int {
    let root = try await submit(.settingsReset, ["origin": try Self.canonicalOrigin(origin)])
    guard Set(root.keys) == ["schemaVersion", "resetCount"],
      let count = root["resetCount"] as? Int, count >= 0
    else { throw ShaarSiteDataError.malformedResponse }
    return count
  }

  public func origins() async throws -> [String] {
    let root = try await submit(.settingsOrigins, [:])
    guard Set(root.keys) == ["schemaVersion", "origins"],
      let values = root["origins"] as? [String]
    else { throw ShaarSiteDataError.malformedResponse }
    let canonical = try values.map(Self.canonicalOrigin)
    guard canonical == canonical.sorted(), Set(canonical).count == canonical.count else {
      throw ShaarSiteDataError.malformedResponse
    }
    return canonical
  }

  public func clearSiteData(
    origin: String, includeCookies: Bool = true,
    includeStorage: Bool = true
  ) async throws {
    guard includeCookies || includeStorage else { throw ShaarSiteDataError.malformedResponse }
    let root = try await submit(
      .siteDataClear,
      [
        "origin": try Self.canonicalOrigin(origin), "includeCookies": includeCookies,
        "includeStorage": includeStorage,
      ])
    guard Set(root.keys) == ["schemaVersion", "complete"],
      root["complete"] as? Bool == true
    else { throw ShaarSiteDataError.malformedResponse }
  }

  public func clearBrowsingData(types: [String], sinceUnixMs: Int64? = nil) async throws
    -> [String]
  {
    guard !types.isEmpty, Set(types).count == types.count,
      types.allSatisfy({ ["cache", "siteData"].contains($0) }),
      sinceUnixMs.map({ $0 >= 0 }) ?? true
    else { throw ShaarSiteDataError.malformedResponse }
    var args: [String: Any] = ["types": types]
    if let sinceUnixMs { args["sinceUnixMs"] = sinceUnixMs }
    let root = try await submit(.browsingDataClear, args)
    guard Set(root.keys) == ["schemaVersion", "clearedTypes", "complete"],
      let cleared = root["clearedTypes"] as? [String], root["complete"] as? Bool == true,
      cleared == types.sorted()
    else { throw ShaarSiteDataError.malformedResponse }
    return cleared
  }

  public func clearSelectedTabCookies(origin: String) async throws {
    let root = try await submit(
      .siteCookiesClear,
      [
        "origin": try Self.canonicalOrigin(origin)
      ])
    guard Set(root.keys) == ["schemaVersion", "complete"],
      root["complete"] as? Bool == true
    else { throw ShaarSiteDataError.malformedResponse }
  }

  public func thirdPartyCookiePolicy() async throws -> ShaarThirdPartyCookiePolicy {
    try Self.decodeCookiePolicy(await submit(.thirdPartyCookiesGet, [:]))
  }

  public func setThirdPartyCookiesBlocked(_ blocked: Bool) async throws
    -> ShaarThirdPartyCookiePolicy
  {
    try Self.decodeCookiePolicy(
      await submit(.thirdPartyCookiesSet, ["blocked": blocked]))
  }

  private static let settingNames: Set<String> = [
    "microphone", "camera", "location", "notifications", "popups", "sound",
  ]

  private static func decodeCookiePolicy(_ root: [String: Any]) throws
    -> ShaarThirdPartyCookiePolicy
  {
    guard Set(root.keys) == ["schemaVersion", "blocked", "managed"],
      let blocked = root["blocked"] as? Bool, let managed = root["managed"] as? Bool
    else { throw ShaarSiteDataError.malformedResponse }
    return ShaarThirdPartyCookiePolicy(blocked: blocked, managed: managed)
  }

  private func submit(_ operation: ShaarSiteDataOperation, _ body: [String: Any]) async throws
    -> [String: Any]
  {
    var arguments = body
    arguments["schemaVersion"] = 1
    let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
    let response = try await transport.submit(
      profileID: profileID, operation: operation, arguments: data)
    guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
      object["schemaVersion"] as? Int == 1
    else { throw ShaarSiteDataError.malformedResponse }
    return object
  }

  private static func canonicalOrigin(_ value: String) throws -> String {
    guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
      ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty,
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      url.path.isEmpty || url.path == "/"
    else { throw ShaarSiteDataError.invalidOrigin }
    let normalized = "\(scheme)://\(host.lowercased())" + (url.port.map { ":\($0)" } ?? "")
    return normalized
  }
}
