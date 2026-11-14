// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

enum JavaScriptDialogKind: String, Equatable {
  case alert, confirm, prompt, beforeUnload
}

struct JavaScriptDialogRequest: Identifiable, Equatable {
  let id: String
  let profileID: UUID
  let tabID: UUID
  let pageURL: URL
  let origin: String
  let message: String
  let defaultPrompt: String
  let kind: JavaScriptDialogKind

  init?(payload: [String: Any]) {
    guard let id = payload["id"] as? String, !id.isEmpty, id.utf8.count <= 64,
      let profileID = (payload["profileID"] as? String).flatMap(UUID.init(uuidString:)),
      let tabID = (payload["tabID"] as? String).flatMap(UUID.init(uuidString:)),
      let page = payload["pageURL"] as? String, page.utf8.count <= 4096,
      let pageURL = URL(string: page), NavigationInput.isWebURL(pageURL),
      let origin = payload["origin"] as? String, origin.utf8.count <= 2048,
      let kind = (payload["dialogType"] as? String).flatMap(JavaScriptDialogKind.init(rawValue:)),
      let message = payload["message"] as? String, message.utf8.count <= 4096,
      let defaultPrompt = payload["defaultPrompt"] as? String,
      defaultPrompt.utf8.count <= 4096
    else { return nil }
    self.id = id
    self.profileID = profileID
    self.tabID = tabID
    self.pageURL = pageURL
    self.origin = origin
    self.message = message
    self.defaultPrompt = defaultPrompt
    self.kind = kind
  }

  var sheetID: String { "javascript-dialog-\(id)" }

  func matches(_ session: BrowserSession) -> Bool {
    session.selectedSpace.profileID == profileID
      && session.selectedPage?.tab.id == tabID
      && session.selectedPage?.tab.url == pageURL
      && session.profileID(forTabID: tabID) == profileID
  }
}
