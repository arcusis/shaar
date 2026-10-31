// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import Foundation
import SwiftUI
import Testing
import XCTest

@testable import ArcusisBrowser

@Suite @MainActor
struct SidebarDropTests {
  @Test func tabDropCreatesAndExtendsSplitThenRespectsPaneCap() throws {
    let store = BrowserStore()
    let space = store.session.selectedSpaceID
    let ids = (0..<5).map { _ in store.session.open(URL(string: "https://\(UUID()).example")!)! }
    store.splitTabs(ids[0], ids[1])
    let first = SidebarTransfer.tab(
      sessionID: store.dragSessionID, sourceSpaceID: space, tabID: ids[2])
    #expect(store.dropTabIntoSidebarSplit(first, target: ids[0]))
    let second = SidebarTransfer.tab(
      sessionID: store.dragSessionID, sourceSpaceID: space, tabID: ids[3])
    #expect(store.dropTabIntoSidebarSplit(second, target: ids[1]))
    let split = try #require(store.session.selectedSpace.splits.first)
    #expect(split.tabIDs.count == BrowserSplit.maxPanes)
    let capped = SidebarTransfer.tab(
      sessionID: store.dragSessionID, sourceSpaceID: space, tabID: ids[4])
    #expect(!store.dropTabIntoSidebarSplit(capped, target: ids[0]))
    store.unsplitTab(ids[3])
    #expect(store.session.selectedSpace.splits.first?.tabIDs.count == 3)
    #expect(store.session.selectedSpace.tabs.contains { $0.id == ids[3] })
  }

  @Test func draggingSplitPaneToTodaySectionRemovesItFromSplit() throws {
    let store = BrowserStore()
    let space = store.session.selectedSpaceID
    let first = store.session.open(URL(string: "https://one.example")!)!
    let second = store.session.open(URL(string: "https://two.example")!)!
    store.splitTabs(first, second)
    let transfer = store.beginTabDrag(second, spaceID: space, fromSplitPane: true)
    let accepted = store.acceptSidebarDrop(transfer, into: space, pinned: false)
    #expect(accepted)
    #expect(store.session.selectedSpace.splits.isEmpty)
    #expect(store.session.selectedSpace.tabs.contains { $0.id == second })
  }

  @Test func clearTodayTabsClosesOnlyCurrentSpaceUnpinnedTabs() throws {
    let store = BrowserStore()
    let space = store.session.selectedSpaceID
    let pinned = store.session.open(URL(string: "https://pinned.example")!)!
    store.togglePin(pinned)
    let today = store.session.open(URL(string: "https://today.example")!)!
    let favorite = store.session.addFavorite(
      profileID: store.session.selectedSpace.profileID,
      originalURL: URL(string: "https://favorite.example")!, title: "Favorite")
    #expect(favorite != nil)
    store.clearTodayTabs(in: space)
    #expect(store.session.selectedSpace.tabs.map(\.id) == [pinned])
    #expect(store.session.recentlyClosedTabs(in: space).contains { $0.id == today })
    #expect(store.session.favorites.count == 1)
  }

  @Test func favoriteDropRestoresFavoriteAsPinnedOrTodayTab() throws {
    let store = BrowserStore()
    let space = store.session.selectedSpace
    for (host, pinned) in [("pinned.example", true), ("today.example", false)] {
      let addedFavorite = store.session.addFavorite(
        profileID: space.profileID, originalURL: URL(string: "https://\(host)")!, title: host)
      let favorite = try #require(addedFavorite)
      let pageID = try #require(
        store.session.favoritePages.first { $0.favoriteID == favorite }?.tab.id)
      let restored = store.restoreFavoriteAsTab(favorite, in: space.id, pinned: pinned)
      #expect(restored)
      #expect(store.session.selectedSpace.tabs.first { $0.id == pageID }?.isPinned == pinned)
      #expect(!store.session.favorites.contains { $0.id == favorite })
    }
    try store.session.validate()
  }

  @Test func tidySiteFallbackCreatesTodayFoldersAndLeavesSingletonsLoose() async throws {
    let store = BrowserStore()
    let space = store.session.selectedSpaceID
    _ = store.session.open(URL(string: "https://alpha.example/one")!)
    _ = store.session.open(URL(string: "https://alpha.example/two")!)
    let openedSingleton = store.session.open(URL(string: "https://beta.example/only")!)
    let singleton = try #require(openedSingleton)
    let before = store.session.selectedSpace.items(isPinned: false)
    let groups = await SidebarSiteGrouping().groups(for: store.session.selectedSpace.tabs)
    store.applyTidyGroups(groups, in: space)
    let folders = store.session.selectedSpace.folders
    #expect(folders.count == 1)
    #expect(folders[0].name == "alpha.example")
    #expect(!folders[0].isPinned)
    #expect(store.session.selectedSpace.tabs.first { $0.id == singleton }?.folderID == nil)
    #expect(store.session.selectedSpace.items(isPinned: false) != before)
    try store.session.validate()
  }
}

@MainActor
final class SidebarDropVisualTests: XCTestCase {
  func testCapturesAddToSplitHoverState() async throws {
    try XCTSkipUnless(
      SidebarVisualCaptureSupport.enabled, "Visual capture requires explicit CI opt-in")
    let view = SidebarSplitRow(
      segments: [
        .init(id: UUID(), title: "Research", favicon: nil),
        .init(id: UUID(), title: "Planning", favicon: nil),
      ], focusedID: nil, isSelected: false, onSelect: { _ in }, onClose: { _ in },
      onDrag: { id in .tab(sessionID: UUID(), sourceSpaceID: UUID(), tabID: id) }
    )
    .frame(width: 240)
    .overlay {
      SidebarDropHint(title: "Add to Split", symbol: "rectangle.split.2x1", isTargeted: true)
    }
    let mounted = try MountedChromeSidebar(
      view: view, size: NSSize(width: 260, height: 80), appearance: .aqua)
    defer { mounted.close() }
    let root = try SidebarVisualCaptureSupport.prepare()
    let file = root.appendingPathComponent("sidebar-add-to-split-hover.png")
    let size = try await mounted.capture(to: file, requiredText: ["Add to Split"])
    try SidebarVisualCaptureSupport.record(
      root: root,
      entry: [
        "name": file.lastPathComponent,
        "width": size.width,
        "height": size.height,
        "scenario": "add-to-split-hover",
        "componentOnly": true,
        "physicalInput": false,
        "visualAcceptance": false,
      ])
  }
}
