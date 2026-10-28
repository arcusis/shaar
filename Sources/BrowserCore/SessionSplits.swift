import Foundation

extension BrowserSession {
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
      spaces[index].tabs.contains(where: { $0.id == target })
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
