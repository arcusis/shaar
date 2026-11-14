// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation

struct SidebarSplitMenuCandidateRanges {
  let before: Range<Int>
  let after: Range<Int>

  init(tabs: [BrowserTab], excluding tabID: UUID) {
    if let omittedIndex = tabs.firstIndex(where: { $0.id == tabID }) {
      before = 0..<omittedIndex
      after = (omittedIndex + 1)..<tabs.count
    } else {
      before = 0..<tabs.count
      after = tabs.count..<tabs.count
    }
  }
}

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

  private struct GroupPosition {
    let group: Group
    let index: Int
  }

  private let boundariesByTabID: [UUID: SidebarTabMoveBoundary]
  private let tabs: [BrowserTab]
  private let tabsByID: [UUID: BrowserTab]
  private let idsByGroup: [Group: [UUID]]
  private let positionsByTabID: [UUID: GroupPosition]

  init(tabs: [BrowserTab]) {
    self.tabs = tabs
    var tabsByID: [UUID: BrowserTab] = [:]
    var endsByGroup: [Group: Ends] = [:]
    var idsByGroup: [Group: [UUID]] = [:]
    var positionsByTabID: [UUID: GroupPosition] = [:]
    for tab in tabs {
      let group = Group(isPinned: tab.isPinned, folderID: tab.folderID)
      if tabsByID[tab.id] == nil { tabsByID[tab.id] = tab }
      let groupIndex = idsByGroup[group, default: []].count
      idsByGroup[group, default: []].append(tab.id)
      if positionsByTabID[tab.id] == nil {
        positionsByTabID[tab.id] = GroupPosition(group: group, index: groupIndex)
      }
      if var ends = endsByGroup[group] {
        ends.lastID = tab.id
        endsByGroup[group] = ends
      } else {
        endsByGroup[group] = Ends(firstID: tab.id, lastID: tab.id)
      }
    }
    self.tabsByID = tabsByID
    self.idsByGroup = idsByGroup
    self.positionsByTabID = positionsByTabID

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
    guard targetID != sourceID, tabsByID[targetID] != nil,
      let position = positionsByTabID[targetID],
      let groupIDs = idsByGroup[position.group]
    else {
      return nil
    }
    guard after else { return .before(targetID) }
    for index in (position.index + 1)..<groupIDs.endIndex where groupIDs[index] != sourceID {
      return .before(groupIDs[index])
    }
    return .end
  }
}
