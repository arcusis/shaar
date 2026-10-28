import Foundation

extension BrowserSession {
  @discardableResult
  public mutating func splitTabs(_ first: UUID, _ second: UUID, in spaceID: UUID) -> Bool {
    guard first != second, let index = spaces.firstIndex(where: { $0.id == spaceID }),
      spaces[index].tabs.contains(where: { $0.id == first }),
      spaces[index].tabs.contains(where: { $0.id == second })
    else { return false }
    spaces[index].splits.removeAll { $0.tabIDs.contains(first) || $0.tabIDs.contains(second) }
    spaces[index].splits.append(BrowserSplit(tabIDs: [first, second]))
    selectTab(first, in: spaceID)
    return true
  }

  public mutating func unsplitTab(_ tabID: UUID, in spaceID: UUID) {
    guard let index = spaces.firstIndex(where: { $0.id == spaceID }),
      let split = spaces[index].splits.firstIndex(where: { $0.tabIDs.contains(tabID) }) else { return }
    let remaining = spaces[index].splits[split].tabIDs.first { $0 != tabID }
    spaces[index].splits[split].tabIDs.removeAll { $0 == tabID }
    spaces[index].reconcileSplits()
    if spaces[index].selectedTabID == tabID, let remaining {
      spaces[index].selectedTabID = remaining
    }
  }

  public mutating func setSplitRatio(_ ratio: Double, splitID: UUID, in spaceID: UUID) {
    guard ratio.isFinite, let index = spaces.firstIndex(where: { $0.id == spaceID }),
      let split = spaces[index].splits.firstIndex(where: { $0.id == splitID }) else { return }
    spaces[index].splits[split].ratio = min(1, max(0, ratio))
  }
}
