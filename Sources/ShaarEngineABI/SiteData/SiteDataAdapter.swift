// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

private func isJSONBoolean(_ value: Any?) -> Bool {
  guard let number = value as? NSNumber else { return false }
  return CFGetTypeID(number) == CFBooleanGetTypeID()
}

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
  case siteCookieItems = 709
  case siteCookieSet = 710
  case siteCookieDelete = 711
}

public enum ShaarCookieSameSite: String, CaseIterable, Sendable {
  case unspecified = "Unspecified"
  case lax = "Lax"
  case strict = "Strict"
  case none = "None"
}

public struct ShaarSiteCookie: Equatable, Sendable, Identifiable {
  public let name: String
  public let value: String
  public let domain: String
  public let path: String
  public let secure: Bool
  public let httpOnly: Bool
  public let sameSite: ShaarCookieSameSite
  public let expiresUnixMs: Int64?
  public let partitionSite: String?
  public let partitionCrossSite: Bool?
  public let sourceScheme: Int
  public let sourcePort: Int

  public var id: String {
    [
      name, domain, path, partitionSite ?? "", partitionCrossSite.map(String.init) ?? "",
      String(sourceScheme), String(sourcePort),
    ]
    .joined(separator: "\u{0}")
  }

  public init?(dictionary: [String: Any]) {
    guard
      Set(dictionary.keys) == [
        "name", "value", "domain", "path", "secure", "httpOnly", "sameSite",
        "expiresUnixMs", "partitionSite", "partitionCrossSite", "sourceScheme", "sourcePort",
      ],
      let name = dictionary["name"] as? String, name.count <= 256,
      let value = dictionary["value"] as? String, value.count <= 4096,
      let domain = dictionary["domain"] as? String, !domain.isEmpty, domain.count <= 256,
      let path = dictionary["path"] as? String, path.hasPrefix("/"), path.count <= 1024,
      isJSONBoolean(dictionary["secure"]),
      let secure = dictionary["secure"] as? Bool,
      isJSONBoolean(dictionary["httpOnly"]),
      let httpOnly = dictionary["httpOnly"] as? Bool,
      let rawSameSite = dictionary["sameSite"] as? String,
      let sameSite = ShaarCookieSameSite(rawValue: rawSameSite),
      !isJSONBoolean(dictionary["sourceScheme"]),
      let sourceScheme = dictionary["sourceScheme"] as? Int, (0...2).contains(sourceScheme),
      !isJSONBoolean(dictionary["sourcePort"]),
      let sourcePort = dictionary["sourcePort"] as? Int, (-1...65535).contains(sourcePort)
    else { return nil }
    let expires = dictionary["expiresUnixMs"]
    let partition = dictionary["partitionSite"]
    let crossSite = dictionary["partitionCrossSite"]
    guard expires is NSNull || (!isJSONBoolean(expires) && expires as? Int64 != nil),
      partition is NSNull || partition as? String != nil,
      crossSite is NSNull || (isJSONBoolean(crossSite) && crossSite as? Bool != nil),
      (partition is NSNull) == (crossSite is NSNull)
    else { return nil }
    self.name = name
    self.value = value
    self.domain = domain
    self.path = path
    self.secure = secure
    self.httpOnly = httpOnly
    self.sameSite = sameSite
    expiresUnixMs = expires as? Int64
    partitionSite = partition as? String
    partitionCrossSite = crossSite as? Bool
    self.sourceScheme = sourceScheme
    self.sourcePort = sourcePort
  }

  public var identity: [String: Any] {
    [
      "name": name, "domain": domain, "path": path,
      "partitionSite": partitionSite ?? NSNull(),
      "partitionCrossSite": partitionCrossSite.map { $0 as Any } ?? NSNull(),
      "sourceScheme": sourceScheme, "sourcePort": sourcePort,
    ]
  }
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
}

public protocol ShaarSiteDataTransport: Sendable {
  func submit(operation: ShaarSiteDataOperation, arguments: Data) async throws -> Data
}

/// Typed site-data calls over the Shaar ABI.
public struct ShaarSiteDataAdapter: Sendable {
  private let transport: any ShaarSiteDataTransport
  public let implementation: ShaarEngineImplementation

  public init(
    implementation: ShaarEngineImplementation = .shippingDefault,
    transport: any ShaarSiteDataTransport
  ) {
    self.implementation = implementation
    self.transport = transport
  }

  public static func selected(
    implementation: ShaarEngineImplementation,
    transport: any ShaarSiteDataTransport
  ) -> Self? {
    guard implementation == .shaar else { return nil }
    return Self(implementation: implementation, transport: transport)
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
        isJSONBoolean(value["isDefault"]),
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
    guard Self.settableSettingNames.contains(type) else {
      throw ShaarSiteDataError.malformedResponse
    }
    let root = try await submit(
      .settingsSet,
      [
        "origin": try Self.canonicalOrigin(origin), "type": type, "value": value.rawValue,
      ])
    guard Set(root.keys) == ["schemaVersion", "value", "isDefault"],
      let raw = root["value"] as? String, let setting = ShaarSiteSettingValue(rawValue: raw),
      isJSONBoolean(root["isDefault"]),
      let isDefault = root["isDefault"] as? Bool
    else { throw ShaarSiteDataError.malformedResponse }
    return ShaarSiteSetting(value: setting, isDefault: isDefault)
  }

  public func reset(origin: String) async throws -> Int {
    let root = try await submit(.settingsReset, ["origin": try Self.canonicalOrigin(origin)])
    guard Set(root.keys) == ["schemaVersion", "resetCount"],
      !isJSONBoolean(root["resetCount"]),
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
      isJSONBoolean(root["complete"]),
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
      isJSONBoolean(root["complete"]),
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
      isJSONBoolean(root["complete"]),
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

  public func cookies(origin: String) async throws -> [ShaarSiteCookie] {
    let root = try await submit(.siteCookieItems, ["origin": try Self.canonicalOrigin(origin)])
    guard Set(root.keys) == ["schemaVersion", "cookies"],
      let items = root["cookies"] as? [[String: Any]], items.count <= 500,
      items.allSatisfy({ ShaarSiteCookie(dictionary: $0) != nil })
    else { throw ShaarSiteDataError.malformedResponse }
    return items.compactMap(ShaarSiteCookie.init(dictionary:))
  }

  public func setCookie(
    _ cookie: ShaarSiteCookie, value: String, secure: Bool, httpOnly: Bool,
    sameSite: ShaarCookieSameSite, origin: String
  ) async throws {
    guard value.count <= 4096 else { throw ShaarSiteDataError.malformedResponse }
    var arguments = cookie.identity
    arguments["origin"] = try Self.canonicalOrigin(origin)
    arguments["value"] = value
    arguments["secure"] = secure
    arguments["httpOnly"] = httpOnly
    arguments["sameSite"] = sameSite.rawValue
    try await requireComplete(.siteCookieSet, arguments)
  }

  public func deleteCookie(_ cookie: ShaarSiteCookie, origin: String) async throws {
    var arguments = cookie.identity
    arguments["origin"] = try Self.canonicalOrigin(origin)
    try await requireComplete(.siteCookieDelete, arguments)
  }

  private func requireComplete(_ operation: ShaarSiteDataOperation, _ arguments: [String: Any])
    async throws
  {
    let root = try await submit(operation, arguments)
    guard Set(root.keys) == ["schemaVersion", "complete"],
      isJSONBoolean(root["complete"]),
      root["complete"] as? Bool == true
    else { throw ShaarSiteDataError.malformedResponse }
  }

  private static let settingNames: Set<String> = [
    "microphone", "camera", "location", "notifications", "popups", "sound",
    "midi", "protocolHandlers",
  ]

  /// Protocol handlers are listed and reset with the other exceptions. They are
  /// not a content setting, so the exceptions editor cannot assign them.
  private static let settableSettingNames: Set<String> = [
    "microphone", "camera", "location", "notifications", "popups", "sound", "midi",
  ]

  private static func decodeCookiePolicy(_ root: [String: Any]) throws
    -> ShaarThirdPartyCookiePolicy
  {
    guard Set(root.keys) == ["schemaVersion", "blocked", "managed"],
      isJSONBoolean(root["blocked"]), isJSONBoolean(root["managed"]),
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
    let response = try await transport.submit(operation: operation, arguments: data)
    guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
      let schemaVersion = object["schemaVersion"] as? NSNumber,
      !isJSONBoolean(schemaVersion), Int(exactly: schemaVersion.doubleValue) == 1
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
