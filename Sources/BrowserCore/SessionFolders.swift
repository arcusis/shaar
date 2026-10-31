// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

public enum SidebarSection: Sendable, Equatable {
  case pinned, today
  public var isPinned: Bool {
    if case .pinned = self { return true }
    return false
  }
}

extension BrowserSession {
  public mutating func selectFolder(_ id: UUID, in spaceID: UUID) {
    guard let index = spaces.firstIndex(where: { $0.id == spaceID }),
      spaces[index].folders.contains(where: { $0.id == id })
    else { return }
    selectedSpaceID = spaceID
    spaces[index].expandFolderPath(id)
  }

  @discardableResult
  public mutating func addFolder(name: String, in spaceID: UUID, parentID: UUID? = nil) -> UUID? {
    addFolder(name: name, in: spaceID, section: .pinned, parentID: parentID)
  }

  @discardableResult
  public mutating func addFolder(
    name: String, in spaceID: UUID, section: SidebarSection, parentID: UUID? = nil
  ) -> UUID? {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, let index = spaces.firstIndex(where: { $0.id == spaceID }),
      parentID == nil
        || spaces[index].folders.contains(where: {
          $0.id == parentID && $0.isPinned == section.isPinned
        })
    else { return nil }
    let folder = BrowserFolder(name: name, parentID: parentID, isPinned: section.isPinned)
    spaces[index].folders.append(folder)
    spaces[index].expandFolderPath(parentID)
    spaces[index].normalizeFolders()
    return folder.id
  }

  @discardableResult
  public mutating func renameFolder(_ id: UUID, in spaceID: UUID, name: String) -> Bool {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, let space = spaces.firstIndex(where: { $0.id == spaceID }),
      let folder = spaces[space].folders.firstIndex(where: { $0.id == id })
    else { return false }
    spaces[space].folders[folder].name = name
    return true
  }

  @discardableResult
  public mutating func toggleFolder(_ id: UUID, in spaceID: UUID) -> Bool {
    guard let space = spaces.firstIndex(where: { $0.id == spaceID }),
      let folder = spaces[space].folders.firstIndex(where: { $0.id == id })
    else { return false }
    spaces[space].folders[folder].isCollapsed.toggle()
    return true
  }

  /// Removing a container keeps every page and promotes its immediate contents.
  @discardableResult
  public mutating func removeFolder(_ id: UUID, in spaceID: UUID) -> Bool {
    guard let index = spaces.firstIndex(where: { $0.id == spaceID }),
      let folder = spaces[index].folders.first(where: { $0.id == id })
    else { return false }
    var space = spaces[index]
    for i in space.folders.indices where space.folders[i].parentID == id {
      space.folders[i].parentID = folder.parentID
    }
    for i in space.tabs.indices where space.tabs[i].folderID == id {
      space.tabs[i].folderID = folder.parentID
    }
    space.folders.removeAll { $0.id == id }
    space.normalizeFolders()
    spaces[index] = space
    return true
  }

  @discardableResult
  public mutating func moveFolder(
    _ id: UUID, from sourceID: UUID, to destinationID: UUID,
    parentID: UUID? = nil, before targetID: UUID? = nil
  ) -> Bool {
    guard let source = spaces.firstIndex(where: { $0.id == sourceID }),
      let destination = spaces.firstIndex(where: { $0.id == destinationID }),
      spaces[source].profileID == spaces[destination].profileID,
      spaces[source].folders.contains(where: { $0.id == id }),
      parentID == nil || spaces[destination].folders.contains(where: { $0.id == parentID })
    else { return false }
    let tree = spaces[source].subtreeIDs(id)
    if let parentID, tree.contains(parentID) { return false }
    if let targetID {
      guard !tree.contains(targetID),
        spaces[destination].folders.contains(where: { $0.id == targetID && $0.parentID == parentID }
        )
      else { return false }
    }
    let members = spaces[source].tabs.filter { $0.folderID.map(tree.contains) == true }
    let memberIDs = Set(members.map(\.id))
    let selected = spaces[source].selectedTabID
    let followsSelection =
      sourceID == selectedSpaceID
      && spaces[source].selectedFavoriteID == nil && selected.map(memberIDs.contains) == true
    var movedFolders = spaces[source].folders.filter { tree.contains($0.id) }
    if let root = movedFolders.firstIndex(where: { $0.id == id }) {
      movedFolders[root].parentID = parentID
    }
    var updated = spaces
    updated[source].folders.removeAll { tree.contains($0.id) }
    let insertion =
      targetID.flatMap { anchor in updated[destination].folders.firstIndex { $0.id == anchor } }
      ?? updated[destination].folders.endIndex
    updated[destination].folders.insert(contentsOf: movedFolders, at: insertion)
    if source != destination {
      let oldPosition = spaces[source].tabs.firstIndex { $0.id == selected } ?? 0
      updated[source].tabs.removeAll { memberIDs.contains($0.id) }
      updated[source].reconcileSplits()
      updated[destination].tabs += members
      if selected.map(memberIDs.contains) == true {
        let remaining = updated[source].tabs
        updated[source].selectedTabID =
          remaining.isEmpty ? nil : remaining[min(oldPosition, remaining.count - 1)].id
      }
      if followsSelection {
        updated[destination].selectedTabID = selected
        updated[destination].selectedFavoriteID = nil
      } else if updated[destination].selectedTabID == nil {
        updated[destination].selectedTabID = members.first?.id
      }
    }
    updated[source].normalizeFolders()
    updated[destination].normalizeFolders()
    updated[destination].expandFolderPath(parentID)
    guard updated != spaces else { return false }
    spaces = updated
    if followsSelection { selectedSpaceID = destinationID }
    return true
  }
}
