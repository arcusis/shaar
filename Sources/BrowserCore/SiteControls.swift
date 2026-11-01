// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Per-site permissions the site control center shows, in display order.
public enum SitePermission: String, CaseIterable, Sendable {
  case microphone, camera, location, notifications, popups, sound, autoPictureInPicture

  /// Chromium's content-setting name, or nil when the pinned engine has no per-site setting.
  public var engineSettingName: String? {
    switch self {
    case .autoPictureInPicture: nil
    default: rawValue
    }
  }
}

/// A content setting's value as Chromium reports it.
public enum SitePermissionValue: String, Sendable {
  case allow, block, ask
}

public enum SitePermissionValues {
  /// Reads the engine's `{name: {value, isDefault}}` map, ignoring settings it does not show.
  public static func parse(_ settings: [String: Any]) -> [SitePermission: SitePermissionValue] {
    var values: [SitePermission: SitePermissionValue] = [:]
    for permission in SitePermission.allCases {
      guard let name = permission.engineSettingName,
        let entry = settings[name] as? [String: Any],
        let value = (entry["value"] as? String).flatMap(SitePermissionValue.init(rawValue:))
      else { continue }
      values[permission] = value
    }
    return values
  }
}

/// Whether the page's connection is secure, as Chromium judges it.
public enum SiteSecurity: Equatable, Sendable {
  case secure, notSecure, unavailable

  public init(engineLevel: String?) {
    switch engineLevel {
    case "secure": self = .secure
    case "insecure", "certificateError", "mixed": self = .notSecure
    default: self = .unavailable
    }
  }
}

public enum SiteOrigin {
  /// The `scheme://host[:port]` origin of a web page, or nil for pages that are not http(s).
  public static func string(for url: URL) -> String? {
    guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
      let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty
    else { return nil }
    var components = URLComponents()
    components.scheme = scheme
    components.host = host
    components.port = url.port
    return components.string
  }
}
