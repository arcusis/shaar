// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

struct HTTPAuthRequest: Identifiable, Equatable {
  let id: String
  let profileID: UUID
  let tabID: UUID
  let windowID: String
  let host: String
  let realm: String

  init?(payload: [String: Any]) {
    guard let id = payload["id"] as? String, !id.isEmpty, id.utf8.count <= 128,
      let profileID = (payload["profileID"] as? String).flatMap(UUID.init(uuidString:)),
      let tabID = (payload["tabID"] as? String).flatMap(UUID.init(uuidString:)),
      let windowID = payload["windowID"] as? String, !windowID.isEmpty,
      windowID.utf8.count <= 128,
      let host = payload["host"] as? String, !host.isEmpty, host.utf8.count <= 255,
      let realm = payload["realm"] as? String, realm.utf8.count <= 512
    else { return nil }
    self.id = id
    self.profileID = profileID
    self.tabID = tabID
    self.windowID = windowID
    self.host = host
    self.realm = realm
  }

  var sheetID: String { "http-auth-\(id)" }

  func matches(_ session: BrowserSession) -> Bool {
    session.selectedSpace.profileID == profileID
      && session.selectedPage?.tab.id == tabID
      && session.profileID(forTabID: tabID) == profileID
  }
}
