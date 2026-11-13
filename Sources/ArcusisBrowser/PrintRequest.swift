// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import CoreFoundation
import Foundation

struct PrintRequest: Identifiable, Equatable {
  let id: String
  let profileID: UUID
  let tabID: UUID
  let pageURL: URL
  let requestingOrigin: URL
  let frameID: String
  let title: String

  init?(payload: [String: Any]) {
    guard Self.hasSupportedSchemaVersion(payload["schemaVersion"]),
      let id = payload["id"] as? String,
      UUID(uuidString: id) != nil,
      let profileID = (payload["profileID"] as? String).flatMap(UUID.init(uuidString:)),
      let tabID = (payload["tabID"] as? String).flatMap(UUID.init(uuidString:)),
      let pageURLString = payload["pageURL"] as? String,
      pageURLString.utf8.count <= 4096,
      let pageURL = URL(string: pageURLString),
      let originString = payload["origin"] as? String,
      originString.utf8.count <= 2048,
      let requestingOrigin = URL(string: originString),
      let frameID = payload["frameID"] as? String,
      Self.isFrameToken(frameID),
      NavigationInput.isWebURL(pageURL),
      Self.isWebOrigin(requestingOrigin),
      let title = Self.boundedTitle(payload["title"])
    else { return nil }
    self.id = id
    self.profileID = profileID
    self.tabID = tabID
    self.pageURL = pageURL
    self.requestingOrigin = requestingOrigin
    self.frameID = frameID
    self.title = title
  }

  var sheetID: String { "print-\(id)" }

  var hostLabel: String {
    guard let rawHost = requestingOrigin.host() ?? pageURL.host() else {
      return pageURL.absoluteString
    }
    let host = rawHost.contains(":") && !rawHost.hasPrefix("[") ? "[\(rawHost)]" : rawHost
    return requestingOrigin.port.map { "\(host):\($0)" } ?? host
  }

  func matches(
    _ session: BrowserSession, frameID: String? = nil, origin: URL? = nil
  ) -> Bool {
    session.selectedSpace.profileID == profileID
      && session.selectedPage?.tab.id == tabID
      && session.selectedPage?.tab.url == pageURL
      && session.profileID(forTabID: tabID) == profileID
      && (frameID == nil || self.frameID == frameID)
      && (origin == nil || requestingOrigin == origin)
  }

  private static func isFrameToken(_ value: String) -> Bool {
    guard value.utf8.count == 32 else { return false }
    return value.unicodeScalars.allSatisfy {
      (48...57).contains(Int($0.value)) || (65...70).contains(Int($0.value))
        || (97...102).contains(Int($0.value))
    }
  }

  private static func isWebOrigin(_ origin: URL) -> Bool {
    guard origin.host() != nil,
      origin.path.isEmpty || origin.path == "/",
      origin.query == nil,
      origin.fragment == nil,
      origin.user == nil,
      origin.password == nil
    else { return false }
    return ["http", "https"].contains(origin.scheme?.lowercased() ?? "")
  }

  private static func isBidirectionalControl(_ scalar: Unicode.Scalar) -> Bool {
    let value = scalar.value
    return value == 0x061C || value == 0x200E || value == 0x200F
      || (0x202A...0x202E).contains(value) || (0x2066...0x206F).contains(value)
  }

  private static func boundedTitle(_ value: Any?) -> String? {
    guard let value else { return "" }
    guard let title = value as? String, title.utf8.count <= 2048 else { return nil }
    let scalars = title.unicodeScalars.map { scalar -> Unicode.Scalar in
      switch scalar.properties.generalCategory {
      case .control, .format, .lineSeparator, .paragraphSeparator: return " "
      default: return Self.isBidirectionalControl(scalar) ? " " : scalar
      }
    }
    let sanitized = String(String.UnicodeScalarView(scalars))
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return String(sanitized.prefix(256))
  }

  private static func hasSupportedSchemaVersion(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) == CFNumberGetTypeID(),
      !CFNumberIsFloatType(number), number.intValue == 1
    else { return false }
    return true
  }

}
