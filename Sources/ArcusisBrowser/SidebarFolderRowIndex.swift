// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

struct SidebarFolderRowIndex {
  private let foldersByID: [UUID: BrowserFolder]
  private let activeFolderIDs: Set<UUID>
  private let foldersWithContents: Set<UUID>

  init(space: BrowserSpace, activeFolderID: UUID?) {
    let foldersByID = Dictionary(
      space.folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    self.foldersByID = foldersByID
    var activeFolderIDs: Set<UUID> = []
    var next = activeFolderID
    while let folderID = next, let folder = foldersByID[folderID],
      activeFolderIDs.insert(folderID).inserted
    {
      next = folder.parentID
    }
    self.activeFolderIDs = activeFolderIDs
    var foldersWithContents = Set(space.tabs.compactMap(\.folderID))
    for folder in space.folders {
      if let parentID = folder.parentID { foldersWithContents.insert(parentID) }
    }
    self.foldersWithContents = foldersWithContents
  }

  func isActive(_ folderID: UUID) -> Bool {
    activeFolderIDs.contains(folderID)
  }

  func hasContents(_ folderID: UUID) -> Bool {
    foldersWithContents.contains(folderID)
  }

  func pathLabel(to folderID: UUID) -> String {
    var names: [String] = []
    var next: UUID? = folderID
    var visited: Set<UUID> = []
    while let current = next, let folder = foldersByID[current], visited.insert(current).inserted {
      names.append(folder.name)
      next = folder.parentID
    }
    return names.reversed().joined(separator: " / ")
  }
}
