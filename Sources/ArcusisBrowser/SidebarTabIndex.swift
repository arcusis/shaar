// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

struct SidebarTabMoveBoundary: Equatable {
  let isFirst: Bool
  let isLast: Bool
}

struct SidebarTabIndex {
  enum DropSlot: Equatable {
    case before(UUID)
    case end
  }

  private struct Group: Hashable {
    let isPinned: Bool
    let folderID: UUID?
  }

  private struct Ends {
    let firstID: UUID
    var lastID: UUID
  }

  private let boundariesByTabID: [UUID: SidebarTabMoveBoundary]
  private let tabs: [BrowserTab]

  init(tabs: [BrowserTab]) {
    self.tabs = tabs
    var endsByGroup: [Group: Ends] = [:]
    for tab in tabs {
      let group = Group(isPinned: tab.isPinned, folderID: tab.folderID)
      if var ends = endsByGroup[group] {
        ends.lastID = tab.id
        endsByGroup[group] = ends
      } else {
        endsByGroup[group] = Ends(firstID: tab.id, lastID: tab.id)
      }
    }

    var boundaries: [UUID: SidebarTabMoveBoundary] = [:]
    for tab in tabs {
      let ends = endsByGroup[Group(isPinned: tab.isPinned, folderID: tab.folderID)]!
      boundaries[tab.id] = SidebarTabMoveBoundary(
        isFirst: tab.id == ends.firstID,
        isLast: tab.id == ends.lastID
      )
    }
    boundariesByTabID = boundaries
  }

  func boundary(for tabID: UUID) -> SidebarTabMoveBoundary {
    boundariesByTabID[tabID] ?? SidebarTabMoveBoundary(isFirst: true, isLast: true)
  }

  func dropSlot(targetID: UUID, sourceID: UUID, after: Bool) -> DropSlot? {
    guard targetID != sourceID, let target = tabs.first(where: { $0.id == targetID }) else {
      return nil
    }
    guard after else { return .before(targetID) }
    let siblings = tabs.filter {
      $0.id != sourceID && $0.isPinned == target.isPinned && $0.folderID == target.folderID
    }
    guard let index = siblings.firstIndex(where: { $0.id == targetID }) else { return nil }
    let next = siblings.index(after: index)
    return next < siblings.endIndex ? .before(siblings[next].id) : .end
  }
}
