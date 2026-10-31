// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Website permissions the engine forwards for a decision, named as the engine reports them.
public enum WebsitePermissionKind: String, Sendable, CaseIterable {
  case camera, microphone, location, notifications, clipboard, midi
  case multipleDownloads, windowManagement, localFonts, storageAccess

  /// Chromium can grant these for the current visit only; the rest are remembered when allowed.
  public var supportsOneTimeGrant: Bool {
    switch self {
    case .camera, .microphone, .location: true
    default: false
    }
  }
}

public struct WebsitePermissionRequest: Identifiable, Equatable, Sendable {
  public let id: String
  public let profileID: UUID
  public let tabID: UUID
  public let pageURL: URL
  public let requestingOrigin: URL
  public let kinds: [WebsitePermissionKind]

  public init?(
    id: String, profileID: UUID, tabID: UUID, pageURL: URL,
    requestingOrigin: URL, kinds: [WebsitePermissionKind]
  ) {
    let scheme = requestingOrigin.scheme?.lowercased()
    let secureOrigin =
      scheme == "https"
      || (scheme == "http"
        && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(
          requestingOrigin.host()?.lowercased() ?? ""))
    guard !id.isEmpty, id.utf8.count <= 128, NavigationInput.isWebURL(pageURL),
      NavigationInput.isWebURL(requestingOrigin), requestingOrigin.user == nil,
      requestingOrigin.password == nil, requestingOrigin.query == nil,
      requestingOrigin.fragment == nil,
      requestingOrigin.path.isEmpty || requestingOrigin.path == "/",
      secureOrigin, !kinds.isEmpty, Set(kinds).count == kinds.count
    else { return nil }
    self.id = id
    self.profileID = profileID
    self.tabID = tabID
    self.pageURL = pageURL
    self.requestingOrigin = requestingOrigin
    self.kinds = WebsitePermissionKind.allCases.filter(kinds.contains)
  }

  public func matches(_ session: BrowserSession) -> Bool {
    session.selectedSpace.profileID == profileID
      && session.selectedPage?.tab.id == tabID
      && session.selectedPage?.tab.url == pageURL
      && session.profileID(forTabID: tabID) == profileID
  }
}
