// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Foundation
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor
final class BrowserSplitStoreTests: XCTestCase {
  func testSplitShortcutIsAvailableOnlyWhenAnotherPaneCanJoin() throws {
    var session = BrowserSession.fresh()
    let ids = try (0..<5).map {
      try XCTUnwrap(session.open(URL(string: "https://split-\($0).example")!))
    }
    let store = BrowserStore(session: session)
    let space = store.session.selectedSpaceID
    store.perform(.tab(space: space, tab: ids[0]))
    XCTAssertTrue(store.canSplitSelectedTab)
    store.splitTabs(ids[0], ids[1])
    XCTAssertTrue(store.canSplitSelectedTab)
    store.addToSplit(ids[2], beside: ids[0], edge: .right)
    store.addToSplit(ids[3], beside: ids[0], edge: .right)
    store.perform(.tab(space: space, tab: ids[0]))
    XCTAssertEqual(store.selectedSplit?.tabIDs.count, 4)
    XCTAssertFalse(store.canSplitSelectedTab, "a full split cannot accept the fifth tab")

    var pair = BrowserSession.fresh()
    let first = try XCTUnwrap(pair.open(URL(string: "https://first.example")!))
    let second = try XCTUnwrap(pair.open(URL(string: "https://second.example")!))
    let pairStore = BrowserStore(session: pair)
    pairStore.splitTabs(first, second)
    XCTAssertFalse(pairStore.canSplitSelectedTab, "both tabs already share the split")
  }

  func testShortcutUsesMostRecentlySelectedOtherTab() throws {
    var session = BrowserSession.fresh()
    let first = try XCTUnwrap(session.open(URL(string: "https://one.example")!))
    let second = try XCTUnwrap(session.open(URL(string: "https://two.example")!))
    let third = try XCTUnwrap(session.open(URL(string: "https://three.example")!))
    let store = BrowserStore(session: session)
    let space = session.selectedSpaceID
    store.perform(.tab(space: space, tab: first))
    store.perform(.tab(space: space, tab: second))
    store.splitSelectedTab()
    XCTAssertEqual(store.selectedSplit?.tabIDs, [second, first])
    store.focusSplitTab(first)
    XCTAssertEqual(store.session.selectedPage?.tab.id, first)
    store.unsplitTab(first)
    XCTAssertNil(store.selectedSplit)
    XCTAssertEqual(store.session.selectedPage?.tab.id, second)
    XCTAssertTrue(store.session.selectedSpace.tabs.contains { $0.id == third })
  }

  func testChoosingExistingTabCancelsPendingSplitPlacement() throws {
    var session = BrowserSession.fresh()
    let first = try XCTUnwrap(session.open(URL(string: "https://one.example")!))
    let second = try XCTUnwrap(session.open(URL(string: "https://two.example")!))
    let store = BrowserStore(session: session)
    let space = store.session.selectedSpaceID

    store.openSplitPane(beside: first, edge: .right)
    XCTAssertNotNil(store.pendingSplitPlacement)
    store.perform(.tab(space: space, tab: second))
    XCTAssertNil(store.pendingSplitPlacement)

    store.perform(.open(URL(string: "https://later.example")!))
    XCTAssertTrue(store.session.selectedSpace.splits.isEmpty)
  }

  func testSwitchingSpaceCancelsPendingSplitPlacement() throws {
    var session = BrowserSession.fresh()
    let first = try XCTUnwrap(session.open(URL(string: "https://one.example")!))
    let otherSpace = session.spaces[1].id
    let store = BrowserStore(session: session)

    store.openSplitPane(beside: first, edge: .right)
    store.perform(.space(otherSpace))

    XCTAssertEqual(store.session.selectedSpaceID, otherSpace)
    XCTAssertNil(store.pendingSplitPlacement)
  }

  func testSplitPaneAddressEditorUsesThePaneTab() throws {
    var session = BrowserSession.fresh()
    let first = try XCTUnwrap(session.open(URL(string: "https://first-pane.example/path")!))
    let second = try XCTUnwrap(session.open(URL(string: "https://second-pane.example")!))
    let store = BrowserStore(session: session)
    store.splitTabs(first, second)

    store.focusSplitTab(first)
    store.showAddressEditor(tabID: first)

    XCTAssertTrue(store.commandEditsCurrentURL)
    XCTAssertEqual(store.commandQuery, "https://first-pane.example/path")
    store.dismissCommand()
    var reloadedTab: UUID?
    store.onReloadPage = { tabID, _, _ in
      reloadedTab = tabID
      return true
    }
    XCTAssertTrue(store.canReloadPage(first))
    store.focusSplitTab(first)
    XCTAssertTrue(store.reloadCurrentPage())
    XCTAssertEqual(reloadedTab, first)
  }

  func testSplitPaneToolbarBuildsAtMinimumPaneWidth() throws {
    var session = BrowserSession.fresh()
    let first = try XCTUnwrap(session.open(URL(string: "https://first.example")!))
    let second = try XCTUnwrap(session.open(URL(string: "https://second.example")!))
    let store = BrowserStore(session: session)
    store.splitTabs(first, second)
    let host = NSHostingView(rootView: SplitPaneToolbar(store: store, tabID: first, engine: nil))
    host.frame = NSRect(x: 0, y: 0, width: 160, height: 30)
    host.layoutSubtreeIfNeeded()

    XCTAssertGreaterThan(host.fittingSize.width, 0)
    XCTAssertGreaterThan(host.fittingSize.height, 0)
  }

  func testClosingSplitTargetCancelsPendingPaneCommand() throws {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://other.example")!))
    let other = try XCTUnwrap(store.session.selectedSpace.selectedTabID)
    store.perform(.open(URL(string: "https://target.example")!))
    let target = try XCTUnwrap(store.session.selectedSpace.selectedTabID)
    store.openSplitPane(beside: target, edge: .right)
    XCTAssertTrue(store.commandIsOpen)
    XCTAssertEqual(store.pendingSplitPlacement?.target, target)

    store.nativeTabClosed(other)
    XCTAssertTrue(store.commandIsOpen)
    XCTAssertEqual(store.pendingSplitPlacement?.target, target)
    store.nativeTabClosed(target)

    XCTAssertNil(store.pendingSplitPlacement)
    XCTAssertFalse(store.commandIsOpen)
  }

  func testDroppingTabsBuildsAndSeparatesSplits() throws {
    var session = BrowserSession.fresh()
    let ids = try (0..<5).map {
      try XCTUnwrap(session.open(URL(string: "https://t\($0).example")!))
    }
    let store = BrowserStore(session: session)
    let space = store.session.selectedSpaceID
    store.perform(.tab(space: space, tab: ids[0]))

    _ = store.beginTabDrag(ids[1], spaceID: space, fromSplitPane: false)
    XCTAssertFalse(store.canDropTab(beside: ids[1]))
    XCTAssertTrue(store.dropTab(beside: ids[0], edge: .right))
    XCTAssertNil(store.tabDrag)
    _ = store.beginTabDrag(ids[2], spaceID: space, fromSplitPane: false)
    XCTAssertTrue(store.dropTab(beside: ids[1], edge: .bottom))
    _ = store.beginTabDrag(ids[3], spaceID: space, fromSplitPane: false)
    XCTAssertTrue(store.dropTab(beside: ids[0], edge: .top))
    XCTAssertEqual(store.selectedSplit?.tabIDs.count, 4)
    _ = store.beginTabDrag(ids[4], spaceID: space, fromSplitPane: false)
    XCTAssertFalse(store.canDropTab(beside: ids[0]), "a full split takes no new tabs")

    _ = store.beginTabDrag(ids[2], spaceID: space, fromSplitPane: true)
    XCTAssertTrue(store.canDropTab(beside: ids[0]), "panes can rearrange inside a full split")
    XCTAssertTrue(
      store.acceptSidebarDrop(
        .tab(sessionID: store.dragSessionID, sourceSpaceID: space, tabID: ids[2]), into: space))
    XCTAssertEqual(Set(try XCTUnwrap(store.selectedSplit).tabIDs), [ids[0], ids[1], ids[3]])
  }

  func testStartingSameDragAgainCancelsItsEarlierCleanupTask() async throws {
    var session = BrowserSession.fresh()
    let tab = try XCTUnwrap(session.open(URL(string: "https://drag.example")!))
    let store = BrowserStore(session: session)
    let space = store.session.selectedSpaceID
    let item = store.beginTabDrag(tab, spaceID: space, fromSplitPane: false)

    try await Task.sleep(for: .milliseconds(200))
    _ = store.beginTabDrag(tab, spaceID: space, fromSplitPane: false)
    try await Task.sleep(for: .milliseconds(200))

    XCTAssertEqual(store.sidebarDrag, item)
    XCTAssertEqual(store.tabDrag?.tabID, tab)
    store.sidebarDragCleanupTask?.cancel()
    store.tabDragCleanupTask?.cancel()
  }

  func testDeinitializingStoreCancelsDragCleanupTasks() throws {
    var session = BrowserSession.fresh()
    let tab = try XCTUnwrap(session.open(URL(string: "https://drag.example")!))
    var store: BrowserStore? = BrowserStore(session: session)
    let spaceID = try XCTUnwrap(store?.session.selectedSpaceID)
    _ = store?.beginTabDrag(tab, spaceID: spaceID, fromSplitPane: false)
    let sidebarTask = try XCTUnwrap(store?.sidebarDragCleanupTask)
    let tabTask = try XCTUnwrap(store?.tabDragCleanupTask)
    weak var releasedStore: BrowserStore? = store

    store = nil

    XCTAssertNil(releasedStore)
    XCTAssertTrue(sidebarTask.isCancelled)
    XCTAssertTrue(tabTask.isCancelled)
  }

  func testDropEdgeFollowsNearestSide() {
    let size = CGSize(width: 400, height: 300)
    XCTAssertEqual(SplitDropZone.edge(at: CGPoint(x: 20, y: 150), in: size), .left)
    XCTAssertEqual(SplitDropZone.edge(at: CGPoint(x: 390, y: 150), in: size), .right)
    XCTAssertEqual(SplitDropZone.edge(at: CGPoint(x: 200, y: 10), in: size), .top)
    XCTAssertEqual(SplitDropZone.edge(at: CGPoint(x: 200, y: 290), in: size), .bottom)
  }

  func testSplitDropPreviewRespectsReduceMotion() {
    XCTAssertNil(SplitDropZone.previewAnimation(reduceMotion: true))
    XCTAssertNil(SplitDropZone.previewAnimation(reduceMotion: true, override: false))
    XCTAssertNil(SplitDropZone.previewAnimation(reduceMotion: false, override: true))
    XCTAssertNotNil(SplitDropZone.previewAnimation(reduceMotion: false))
  }

  func testSplitDropRejectsStaleTargetWithoutConsumingDrag() throws {
    var session = BrowserSession.fresh()
    let dragged = try XCTUnwrap(session.open(URL(string: "https://drag.example")!))
    let target = try XCTUnwrap(session.open(URL(string: "https://target.example")!))
    let store = BrowserStore(session: session)
    _ = store.beginTabDrag(dragged, spaceID: store.session.selectedSpaceID, fromSplitPane: false)
    XCTAssertFalse(store.canDropTab(beside: UUID()))
    XCTAssertFalse(store.dropTab(beside: UUID(), edge: .right))
    XCTAssertEqual(store.tabDrag?.tabID, dragged)
    XCTAssertTrue(store.dropTab(beside: target, edge: .right))
  }

  func testDropEdgeHoldsNearCornersAndDefaultsForEmptyPages() {
    let size = CGSize(width: 400, height: 400)
    let nearCorner = CGPoint(x: 30, y: 25)
    XCTAssertEqual(SplitDropZone.edge(at: nearCorner, in: size), .top)
    XCTAssertEqual(SplitDropZone.edge(at: nearCorner, in: size, keeping: .left), .left)
    XCTAssertEqual(
      SplitDropZone.edge(at: CGPoint(x: 200, y: 10), in: size, keeping: .left), .top)
    XCTAssertEqual(SplitDropZone.edge(at: .zero, in: .zero), .right)
  }
}
