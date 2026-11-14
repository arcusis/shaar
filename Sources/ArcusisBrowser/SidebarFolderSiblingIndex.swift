// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

struct SidebarFolderSiblingIndex {
  private struct Key: Hashable {
    let parentID: UUID?
    let isPinned: Bool
  }

  private let foldersByKey: [Key: [BrowserFolder]]

  init(folders: [BrowserFolder]) {
    foldersByKey = Dictionary(grouping: folders) {
      Key(parentID: $0.parentID, isPinned: $0.isPinned)
    }
  }

  func siblings(of folder: BrowserFolder) -> [BrowserFolder] {
    foldersByKey[Key(parentID: folder.parentID, isPinned: folder.isPinned)] ?? []
  }
}
