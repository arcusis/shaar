// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Foundation

extension BrowserStore {
  var selectedSplit: BrowserSplit? {
    guard session.selectedSpace.selectedFavoriteID == nil,
      let id = session.selectedSpace.selectedTabID
    else { return nil }
    return session.selectedSpace.splits.first { $0.tabIDs.contains(id) }
  }

  func splitTabs(_ first: UUID, _ second: UUID) {
    guard session.splitTabs(first, second, in: session.selectedSpaceID) else { return }
    save()
  }

  func recordSplitTabSelection() {
    guard session.selectedSpace.selectedFavoriteID == nil,
      let id = session.selectedSpace.selectedTabID
    else { return }
    splitTabRecency.removeAll { $0 == id }
    splitTabRecency.append(id)
    let existing = Set(session.spaces.flatMap { $0.tabs.map(\.id) })
    splitTabRecency.removeAll { !existing.contains($0) }
  }

  /// Adds the most recently used other tab beside the selected one.
  func splitSelectedTab() {
    guard session.selectedSpace.selectedFavoriteID == nil,
      let selected = session.selectedSpace.selectedTabID
    else { return }
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
    session.addToSplit(
      id, beside: placement.target, edge: placement.edge, in: session.selectedSpaceID)
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

  @discardableResult
  func dropTabIntoSidebarSplit(_ item: SidebarTransfer, target: UUID) -> Bool {
    guard case .tab(let sessionID, let source, let tabID) = item,
      sessionID == dragSessionID, source == session.selectedSpaceID,
      session.selectedSpace.tabs.contains(where: { $0.id == target }),
      session.addToSplit(tabID, beside: target, edge: .right, in: session.selectedSpaceID)
    else { return false }
    tabDrag = nil
    save()
    return true
  }

  /// Records the drag so page drop zones can appear; cleared once the mouse button is up.
  func beginTabDrag(_ tabID: UUID, spaceID: UUID, fromSplitPane: Bool) -> SidebarTransfer {
    let drag = TabDrag(tabID: tabID, fromSplitPane: fromSplitPane)
    if tabDrag != drag {
      tabDrag = drag
      Task { @MainActor [weak self] in
        while NSEvent.pressedMouseButtons & 1 != 0 {
          try? await Task.sleep(for: .milliseconds(80))
        }
        // AppKit delivers the drop just after the button comes up; let it land first.
        try? await Task.sleep(for: .milliseconds(300))
        if self?.tabDrag == drag { self?.tabDrag = nil }
      }
    }
    return .tab(sessionID: dragSessionID, sourceSpaceID: spaceID, tabID: tabID)
  }

  /// Whether dropping the dragged tab beside `target` would change anything.
  func canDropTab(beside target: UUID) -> Bool {
    guard let drag = tabDrag, drag.tabID != target,
      session.selectedSpace.tabs.contains(where: { $0.id == drag.tabID })
    else { return false }
    let split = session.selectedSpace.splits.first { $0.tabIDs.contains(target) }
    let joining = split?.tabIDs.contains(drag.tabID) != true
    return !joining || (split?.tabIDs.count ?? 1) < BrowserSplit.maxPanes
  }

  @discardableResult
  func dropTab(beside target: UUID, edge: SplitEdge) -> Bool {
    guard canDropTab(beside: target), let drag = tabDrag else { return false }
    tabDrag = nil
    guard session.addToSplit(drag.tabID, beside: target, edge: edge, in: session.selectedSpaceID)
    else { return false }
    save()
    return true
  }

  /// A pane dragged into the sidebar leaves its split.
  @discardableResult
  func separateDraggedPane(_ tabID: UUID) -> Bool {
    guard tabDrag?.tabID == tabID, tabDrag?.fromSplitPane == true else { return false }
    tabDrag = nil
    session.unsplitTab(tabID, in: session.selectedSpaceID)
    return true
  }
}

/// A tab being dragged from the sidebar or from a split pane's toolbar.
struct TabDrag: Equatable {
  let tabID: UUID
  let fromSplitPane: Bool
}

struct SplitPlacement: Equatable {
  let target: UUID
  let edge: SplitEdge
}
