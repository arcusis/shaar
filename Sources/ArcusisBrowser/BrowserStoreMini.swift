// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

extension BrowserStore {
  @discardableResult
  func receiveMiniTab(_ tab: BrowserTab, in spaceID: UUID, profileID: UUID, archive: Bool) -> Bool {
    updateMiniSession { session in
      guard session.spaces.contains(where: { $0.id == spaceID && $0.profileID == profileID }),
        NavigationInput.isWebURL(tab.url)
      else { return false }
      let previousSpace = session.selectedSpaceID
      session.selectSpace(spaceID)
      guard let id = session.open(tab.url) else { return false }
      _ = session.updateTab(id, url: tab.url, title: tab.title)
      if archive {
        session.closeTab(id)
        session.selectSpace(previousSpace)
      }
      return true
    }
  }
}

enum MiniLinkRoute: Equatable {
  case mini(URL)
  case main(URL)

  static func route(_ url: URL, inMainWindow: Bool) -> MiniLinkRoute? {
    guard NavigationInput.isWebURL(url) else { return nil }
    return inMainWindow ? .main(url) : .mini(url)
  }
}
