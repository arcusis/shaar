import BrowserCore
import Foundation

extension BrowserStore {
  var selectedSplit: BrowserSplit? {
    guard session.selectedSpace.selectedFavoriteID == nil,
      let id = session.selectedSpace.selectedTabID else { return nil }
    return session.selectedSpace.splits.first { $0.tabIDs.contains(id) }
  }

  func splitTabs(_ first: UUID, _ second: UUID) {
    guard session.splitTabs(first, second, in: session.selectedSpaceID) else { return }
    save()
  }

  func recordSplitTabSelection() {
    guard session.selectedSpace.selectedFavoriteID == nil,
      let id = session.selectedSpace.selectedTabID else { return }
    splitTabRecency.removeAll { $0 == id }
    splitTabRecency.append(id)
    let existing = Set(session.spaces.flatMap { $0.tabs.map(\.id) })
    splitTabRecency.removeAll { !existing.contains($0) }
  }

  /// Adds the most recently used other tab beside the selected one.
  func splitSelectedTab() {
    guard session.selectedSpace.selectedFavoriteID == nil,
      let selected = session.selectedSpace.selectedTabID else { return }
    let inSplit = Set(selectedSplit?.tabIDs ?? [selected])
    let ids = Set(session.selectedSpace.tabs.map(\.id)).subtracting(inSplit)
    let recent = splitTabRecency.reversed().first { ids.contains($0) }
    guard let other = recent ?? session.selectedSpace.tabs.last(where: { ids.contains($0.id) })?.id
    else { return }
    if inSplit.count > 1 {
      addToSplit(other, beside: selected, edge: .right)
    } else {
      splitTabs(selected, other)
    }
  }

  var selectedSplitIsFull: Bool {
    (selectedSplit?.tabIDs.count ?? 1) >= BrowserSplit.maxPanes
  }

  func addToSplit(_ tabID: UUID, beside target: UUID, edge: SplitEdge) {
    guard session.addToSplit(tabID, beside: target, edge: edge, in: session.selectedSpaceID)
    else { return }
    save()
  }

  /// Opens the command bar; the page it opens joins the split beside `target`.
  func openSplitPane(beside target: UUID, edge: SplitEdge) {
    guard !selectedSplitIsFull else { return }
    showCommand()
    pendingSplitPlacement = SplitPlacement(target: target, edge: edge)
  }

  func placePendingSplitPane(_ id: UUID) {
    guard let placement = pendingSplitPlacement else { return }
    pendingSplitPlacement = nil
    session.addToSplit(id, beside: placement.target, edge: placement.edge, in: session.selectedSpaceID)
  }

  func applySplitLayout(_ preset: SplitLayoutPreset) {
    guard let split = selectedSplit,
      session.applySplitLayout(preset, splitID: split.id, in: session.selectedSpaceID)
    else { return }
    save()
  }

  func setSplitWeights(_ weights: [Double], at path: [Int], splitID: UUID) {
    session.setSplitWeights(weights, at: path, splitID: splitID, in: session.selectedSpaceID)
    save(deferred: true)
  }

  func focusSplitTab(_ id: UUID) {
    session.selectTab(id, in: session.selectedSpaceID)
    save(deferred: true)
  }

  func unsplitTab(_ id: UUID) {
    session.unsplitTab(id, in: session.selectedSpaceID)
    save()
  }
}

struct SplitPlacement: Equatable {
  let target: UUID
  let edge: SplitEdge
}
