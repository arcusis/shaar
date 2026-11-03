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

  init?(payload: [String: Any]) {
    guard let id = payload["id"] as? String,
      UUID(uuidString: id) != nil,
      let profileID = (payload["profileID"] as? String).flatMap(UUID.init(uuidString:)),
      let tabID = (payload["tabID"] as? String).flatMap(UUID.init(uuidString:)),
      let pageURL = (payload["pageURL"] as? String).flatMap(URL.init(string:)),
      let requestingOrigin = (payload["origin"] as? String).flatMap(URL.init(string:)),
      let frameID = payload["frameID"] as? String,
      NavigationInput.isWebURL(pageURL),
      requestingOrigin.host() != nil
    else { return nil }
    let scheme = requestingOrigin.scheme?.lowercased()
    let secureOrigin =
      scheme == "https"
      || (scheme == "http"
        && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(
          requestingOrigin.host()?.lowercased() ?? ""))
    guard secureOrigin else { return nil }
    self.id = id
    self.profileID = profileID
    self.tabID = tabID
    self.pageURL = pageURL
    self.requestingOrigin = requestingOrigin
    self.frameID = frameID
  }

  var sheetID: String { "desktop-capture-\(id)" }

  func matches(_ session: BrowserSession) -> Bool {
    session.selectedSpace.profileID == profileID
      && session.selectedPage?.tab.id == tabID
      && session.selectedPage?.tab.url == pageURL
      && session.profileID(forTabID: tabID) == profileID
  }
}
