// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import CoreFoundation

/// A password, card, or address save offer from Chromium. The payload never carries a
/// password, a full card number, or a profile path.
public struct SavePromptRequest: Identifiable, Equatable, Sendable {
  public enum Kind: String, Sendable, CaseIterable {
    case password, card, address
  }

  public enum Decision: String, Sendable {
    case save, dismiss, never
  }

  public let id: String
  public let kind: Kind
  public let profileID: UUID
  public let tabID: UUID
  public let windowID: String
  public let origin: URL
  public let pageURL: URL
  public let detail: String
  public let update: Bool

  public init?(payload: [String: Any]) {
    guard Self.hasOnlyAllowedKeys(payload),
      Self.isSchemaVersionOne(payload["schemaVersion"]),
      payload["kind"] as? String == "savePromptRequested",
      let id = Self.identifier(payload["id"]),
      let kind = Self.kind(payload["prompt"]),
      let origin = Self.origin(payload["origin"]),
      let pageURL = Self.page(payload["pageURL"]),
      let detail = Self.detail(payload["detail"]),
      let update = payload["update"] as? Bool,
      Self.updateIsAllowed(update, kind: kind),
      let profileID = Self.uuid(payload["profileID"]),
      let tabID = Self.uuid(payload["tabID"]),
      let windowID = Self.windowID(payload["windowID"])
    else { return nil }
    self.id = id
    self.kind = kind
    self.profileID = profileID
    self.tabID = tabID
    self.windowID = windowID
    self.origin = origin
    self.pageURL = pageURL
    self.detail = detail
    self.update = update
  }

  /// Never-save applies only to a new password. Card, address, and password updates dismiss.
  public var allowsNever: Bool { kind == .password && !update }

  public func matches(_ session: BrowserSession, inPrivateWindow: Bool = false) -> Bool {
    guard !inPrivateWindow,
      session.selectedSpace.profileID == profileID,
      session.selectedPage?.tab.id == tabID,
      session.profileID(forTabID: tabID) == profileID,
      let current = session.selectedPage?.tab.url
    else { return false }
    return Self.samePage(current, pageURL) && Self.sameOrigin(current, origin)
  }

  public func decision(_ choice: Decision, matchesSession: Bool) -> Decision {
    guard matchesSession else { return .dismiss }
    if choice == .never && !allowsNever { return .dismiss }
    return choice
  }

  private static let allowedKeys: Set<String> = [
    "schemaVersion", "kind", "id", "prompt", "origin", "pageURL", "detail", "update",
    "profileID", "tabID", "windowID",
  ]

  private static func hasOnlyAllowedKeys(_ payload: [String: Any]) -> Bool {
    Set(payload.keys).isSubset(of: allowedKeys)
  }

  private static func isSchemaVersionOne(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID()
    else { return false }
    let type = String(cString: number.objCType)
    guard type != "f", type != "d" else { return false }
    return number.intValue == 1
  }

  private static func identifier(_ value: Any?) -> String? {
    guard let id = value as? String, !id.isEmpty, id.utf8.count <= 128 else { return nil }
    return id
  }

  private static func kind(_ value: Any?) -> Kind? {
    guard let raw = value as? String else { return nil }
    return Kind(rawValue: raw)
  }

  private static func uuid(_ value: Any?) -> UUID? {
    guard let text = value as? String else { return nil }
    return UUID(uuidString: text)
  }

  private static func windowID(_ value: Any?) -> String? {
    guard let windowID = value as? String, !windowID.isEmpty, windowID.utf8.count <= 128 else {
      return nil
    }
    return windowID
  }

  private static func updateIsAllowed(_ update: Bool, kind: Kind) -> Bool {
    !update || kind == .password
  }

  private static func detail(_ value: Any?) -> String? {
    guard let detail = value as? String, detail.utf8.count <= 120,
      detail.unicodeScalars.allSatisfy(isPlainPageText)
    else { return nil }
    return detail
  }

  /// Page text is shown as a username, card label, or address. Format characters,
  /// including bidi controls and zero-width marks, are rejected.
  private static func isPlainPageText(_ scalar: Unicode.Scalar) -> Bool {
    let value = scalar.value
    if value < 32 || value == 127 { return false }
    return scalar.properties.generalCategory != .format
  }

  private static func origin(_ value: Any?) -> URL? {
    guard let url = webURL(value), isOrigin(url) else { return nil }
    return url
  }

  /// Queries and fragments can carry tokens. Strip them before retaining the page URL so
  /// login pages such as `/login?next=` can still show a prompt without keeping the token.
  private static func page(_ value: Any?) -> URL? {
    guard let url = webURL(value), url.user == nil, url.password == nil,
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return nil }
    components.query = nil
    components.fragment = nil
    return components.url
  }

  private static func webURL(_ value: Any?) -> URL? {
    guard let text = value as? String, let url = URL(string: text), NavigationInput.isWebURL(url)
    else { return nil }
    return url
  }

  private static func isOrigin(_ url: URL) -> Bool {
    url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
      && (url.path.isEmpty || url.path == "/")
  }

  private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
      && lhs.host()?.lowercased() == rhs.host()?.lowercased()
      && lhs.port == rhs.port
  }

  private static func samePage(_ lhs: URL, _ rhs: URL) -> Bool {
    sameOrigin(lhs, rhs) && lhs.path == rhs.path
  }
}
