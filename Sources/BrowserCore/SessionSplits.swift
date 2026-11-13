// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

extension BrowserSession {
  /// Moves an entire stack as one transaction, retaining pane order, layout and identity.
  @discardableResult
  public mutating func moveSplit(
    _ id: UUID, from sourceID: UUID, to destinationID: UUID, before targetID: UUID? = nil,
    pinned: Bool? = nil, folderID: UUID? = nil
  ) -> Bool {
    guard let source = spaces.first(where: { $0.id == sourceID }),
      let destination = spaces.first(where: { $0.id == destinationID }),
      source.profileID == destination.profileID,
      let split = source.splits.first(where: { $0.id == id }),
      !split.tabIDs.contains(where: { $0 == targetID }),
      folderID == nil
        || destination.folders.contains(where: {
          $0.id == folderID && (pinned == nil || pinned == $0.isPinned)
        })
    else { return false }
    guard let firstTabID = split.tabIDs.first,
      let firstTab = source.tabs.first(where: { $0.id == firstTabID })
    else { return false }
    let destinationPinned =
      folderID.flatMap { folder in
        destination.folders.first { $0.id == folder }?.isPinned
      } ?? pinned ?? firstTab.isPinned
    if let targetID {
      guard
        destination.tabs.contains(where: {
          $0.id == targetID && $0.isPinned == destinationPinned && $0.folderID == folderID
        })
      else { return false }
    }
    let followsSelection =
      selectedSpaceID == sourceID && source.selectedFavoriteID == nil
      && source.selectedTabID.map(split.tabIDs.contains) == true
    var draft = self
    for tab in split.tabIDs {
      _ = draft.moveTab(
        tab, from: sourceID, to: destinationID, before: targetID,
        pinned: destinationPinned, folderID: folderID)
    }
    guard let index = draft.spaces.firstIndex(where: { $0.id == destinationID }) else {
      return false
    }
    draft.spaces[index].splits.removeAll { $0.id == id }
    draft.spaces[index].splits.append(split)
    if followsSelection {
      draft.selectedSpaceID = destinationID
      draft.spaces[index].selectedTabID = source.selectedTabID
      draft.spaces[index].selectedFavoriteID = nil
    }
    guard draft != self, (try? draft.validate()) != nil else { return false }
    self = draft
    return true
  }

  /// Puts `second` to the right of `first`, joining `first`'s split when it has room.
  @discardableResult
  public mutating func splitTabs(_ first: UUID, _ second: UUID, in spaceID: UUID) -> Bool {
    guard addToSplit(second, beside: first, edge: .right, in: spaceID) else { return false }
    selectTab(first, in: spaceID)
    return true
  }

  /// Adds `tabID` beside `target`. Starts a split when `target` is not in one yet.
  @discardableResult
  public mutating func addToSplit(
    _ tabID: UUID, beside target: UUID, edge: SplitEdge, in spaceID: UUID
  ) -> Bool {
    guard tabID != target, let index = spaces.firstIndex(where: { $0.id == spaceID }),
      spaces[index].tabs.contains(where: { $0.id == tabID }),
      let targetTab = spaces[index].tabs.first(where: { $0.id == target })
    else { return false }
    var splits = spaces[index].splits
    if let existing = splits.firstIndex(where: { $0.tabIDs.contains(tabID) }),
      !splits[existing].tabIDs.contains(target)
    {
      splits[existing].root = splits[existing].root.removing(tabID) ?? splits[existing].root
    }
    if let owner = splits.firstIndex(where: { $0.tabIDs.contains(target) }) {
      var root = splits[owner].root.removing(tabID) ?? splits[owner].root
      guard root.paneIDs.count < BrowserSplit.maxPanes else { return false }
      root = root.inserting(tabID, beside: target, edge: edge)
      splits[owner].root = root
    } else {
      let pane = SplitNode.pane(target)
      splits.append(BrowserSplit(root: pane.inserting(tabID, beside: target, edge: edge)))
    }
    spaces[index].splits = splits
    spaces[index].reconcileSplits()
    if let joined = spaces[index].splits.first(where: { $0.tabIDs.contains(target) }) {
      for position in spaces[index].tabs.indices
      where joined.tabIDs.contains(spaces[index].tabs[position].id) {
        spaces[index].tabs[position].isPinned = targetTab.isPinned
        spaces[index].tabs[position].folderID = targetTab.folderID
      }
    }
    selectTab(tabID, in: spaceID)
    return true
  }

  public mutating func unsplitTab(_ tabID: UUID, in spaceID: UUID) {
    guard let index = spaces.firstIndex(where: { $0.id == spaceID }),
      let split = spaces[index].splits.firstIndex(where: { $0.tabIDs.contains(tabID) })
    else { return }
    let remaining = spaces[index].splits[split].tabIDs.first { $0 != tabID }
    if let root = spaces[index].splits[split].root.removing(tabID) {
      spaces[index].splits[split].root = root
    }
    spaces[index].reconcileSplits()
    if spaces[index].selectedTabID == tabID, let remaining {
      spaces[index].selectedTabID = remaining
    }
  }

  public mutating func setSplitWeights(
    _ weights: [Double], at path: [Int], splitID: UUID, in spaceID: UUID
  ) {
    guard let index = spaces.firstIndex(where: { $0.id == spaceID }),
      let split = spaces[index].splits.firstIndex(where: { $0.id == splitID })
    else { return }
    let root = spaces[index].splits[split].root.settingWeights(weights, at: path)
    guard root.isValid else { return }
    spaces[index].splits[split].root = root
  }

  @discardableResult
  public mutating func applySplitLayout(
    _ preset: SplitLayoutPreset, splitID: UUID, in spaceID: UUID
  ) -> Bool {
    guard let index = spaces.firstIndex(where: { $0.id == spaceID }),
      let split = spaces[index].splits.firstIndex(where: { $0.id == splitID }),
      let root = preset.node(for: spaces[index].splits[split].tabIDs)
    else { return false }
    spaces[index].splits[split].root = root
    return true
  }
}
