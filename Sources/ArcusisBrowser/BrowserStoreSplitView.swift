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

  func splitSelectedTab() {
    guard session.selectedSpace.selectedFavoriteID == nil,
      let selected = session.selectedSpace.selectedTabID else { return }
    let ids = Set(session.selectedSpace.tabs.map(\.id))
    let recent = splitTabRecency.reversed().first { $0 != selected && ids.contains($0) }
    guard let other = recent ?? session.selectedSpace.tabs.last(where: { $0.id != selected })?.id else { return }
    splitTabs(selected, other)
  }

  func focusSplitTab(_ id: UUID) {
    session.selectTab(id, in: session.selectedSpaceID)
    save(deferred: true)
  }

  func unsplitTab(_ id: UUID) {
    session.unsplitTab(id, in: session.selectedSpaceID)
    save()
  }

  func setSplitRatio(_ ratio: Double, splitID: UUID) {
    session.setSplitRatio(ratio, splitID: splitID, in: session.selectedSpaceID)
    save(deferred: true)
  }
}
