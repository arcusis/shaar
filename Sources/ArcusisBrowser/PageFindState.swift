// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

/// A find query belongs to one selected document and is never saved in the session.
struct PageFindState: Identifiable {
  let id = UUID()
  let profileID: UUID
  let tabID: UUID
  let pageURL: URL
  var focusRequest = UUID()
  var requestID = UUID()
  var query = ""
  var matchCount: Int?
  var activeMatch = 0
  var searching = false
  var unavailable = false

  var canMove: Bool { !query.isEmpty && (matchCount ?? 0) > 0 && !searching && !unavailable }

  var status: String {
    if query.isEmpty { return "" }
    if unavailable { return PanelsL10n.string("Page unavailable") }
    guard let count = matchCount else { return PanelsL10n.string("Searching…") }
    if count == 0 { return PanelsL10n.string(searching ? "Searching…" : "No matches") }
    if activeMatch > 0 {
      return PanelsL10n.format("%d of %d", .integer(activeMatch), .integer(count))
    }
    return PanelsL10n.plural("%d matches", count: count)
  }

  func matches(_ session: BrowserSession) -> Bool {
    session.selectedSpace.profileID == profileID
      && session.selectedPage?.tab.id == tabID
      && session.selectedPage?.tab.url == pageURL
      && session.profileID(forTabID: tabID) == profileID
  }
}
