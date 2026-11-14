// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

struct SidebarLayoutKey: Hashable {
  struct Folder: Hashable {
    let id: UUID
    let parentID: UUID?
    let isPinned: Bool
    let isCollapsed: Bool

    init(_ folder: BrowserFolder) {
      id = folder.id
      parentID = folder.parentID
      isPinned = folder.isPinned
      isCollapsed = folder.isCollapsed
    }
  }

  struct Tab: Hashable {
    let id: UUID
    let isPinned: Bool
    let folderID: UUID?

    init(_ tab: BrowserTab) {
      id = tab.id
      isPinned = tab.isPinned
      folderID = tab.folderID
    }
  }

  let favoriteIDs: [UUID]
  let folders: [Folder]
  let tabs: [Tab]

  init(favorites: [BrowserFavorite], folders: [BrowserFolder], tabs: [BrowserTab]) {
    favoriteIDs = favorites.map(\.id)
    self.folders = folders.map(Folder.init)
    self.tabs = tabs.map(Tab.init)
  }
}

enum SidebarLayoutIdentity: Hashable {
  case layout(SidebarLayoutKey)
  case constant(String)
}
