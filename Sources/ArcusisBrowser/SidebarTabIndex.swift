import BrowserCore
import Foundation

struct SidebarTabMoveBoundary: Equatable {
  let isFirst: Bool
  let isLast: Bool
}

struct SidebarTabIndex {
  private struct Group: Hashable {
    let isPinned: Bool
    let folderID: UUID?
  }

  private struct Ends {
    let firstID: UUID
    var lastID: UUID
  }

  private let boundariesByTabID: [UUID: SidebarTabMoveBoundary]

  init(tabs: [BrowserTab]) {
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
}
