// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

struct DesktopCaptureRequest: Identifiable, Equatable {
  let id: String
  let profileID: UUID
  let tabID: UUID
  let pageURL: URL
  let requestingOrigin: URL
  let frameID: String
  let allowedKinds: Set<DesktopCaptureSource.Kind>

  init?(payload: [String: Any]) {
    guard let id = payload["id"] as? String,
      UUID(uuidString: id) != nil,
      let profileID = (payload["profileID"] as? String).flatMap(UUID.init(uuidString:)),
      let tabID = (payload["tabID"] as? String).flatMap(UUID.init(uuidString:)),
      let pageURL = (payload["pageURL"] as? String).flatMap(URL.init(string:)),
      let requestingOrigin = (payload["origin"] as? String).flatMap(URL.init(string:)),
      let frameID = payload["frameID"] as? String,
      Self.isFrameToken(frameID),
      NavigationInput.isWebURL(pageURL),
      NavigationInput.isWebURL(requestingOrigin),
      requestingOrigin.path.isEmpty || requestingOrigin.path == "/",
      requestingOrigin.query == nil,
      requestingOrigin.fragment == nil,
      requestingOrigin.user == nil,
      requestingOrigin.password == nil
    else { return nil }
    let scheme = requestingOrigin.scheme?.lowercased()
    let secureOrigin =
      scheme == "https"
      || (scheme == "http"
        && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(
          requestingOrigin.host()?.lowercased() ?? ""))
    guard secureOrigin else { return nil }
    guard let allowedKinds = Self.allowedKinds(from: payload["sourceTypes"]) else { return nil }
    self.id = id
    self.profileID = profileID
    self.tabID = tabID
    self.pageURL = pageURL
    self.requestingOrigin = requestingOrigin
    self.frameID = frameID
    self.allowedKinds = allowedKinds
  }

  func allows(_ kind: DesktopCaptureSource.Kind) -> Bool {
    allowedKinds.contains(kind)
  }

  private static func isFrameToken(_ value: String) -> Bool {
    guard value.utf8.count == 32 else { return false }
    return value.unicodeScalars.allSatisfy {
      (48...57).contains(Int($0.value)) || (65...70).contains(Int($0.value))
        || (97...102).contains(Int($0.value))
    }
  }

  /// Missing source types mean the engine asked for a screen, a window, and a tab.
  private static func allowedKinds(from value: Any?) -> Set<DesktopCaptureSource.Kind>? {
    guard let value else { return [.display, .window, .tab] }
    guard let names = value as? [String], !names.isEmpty else { return nil }
    var kinds: Set<DesktopCaptureSource.Kind> = []
    for name in names {
      switch name {
      case "screen": kinds.insert(.display)
      case "window": kinds.insert(.window)
      case "tab": kinds.insert(.tab)
      default: return nil
      }
    }
    return kinds
  }

  var sheetID: String { "desktop-capture-\(id)" }

  var displayOrigin: String { requestingOrigin.absoluteString }

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
}
