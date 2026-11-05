// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct SidebarDropRuleTests {
  private func fixture() -> (BrowserStore, UUID, [UUID]) {
    let store = BrowserStore()
    let space = store.session.selectedSpaceID
    let tabs = (0..<4).map { store.session.open(URL(string: "https://tab\($0).example")!)! }
    for tab in tabs.prefix(3) { store.togglePin(tab) }
    return (store, space, tabs)
  }

  private func transfer(_ store: BrowserStore, _ space: UUID, _ tab: UUID) -> SidebarTransfer {
    .tab(sessionID: store.dragSessionID, sourceSpaceID: space, tabID: tab)
  }

  @Test func favoritesAcceptOnlySinglePagesIncludingSplitMembers() throws {
    let (store, space, tabs) = fixture()
    store.splitTabs(tabs[0], tabs[1])
    let split = try #require(store.session.selectedSpace.splits.first)
    let created = store.createFolder(name: "Projects", in: space)
    let folder = try #require(created)
    for refused in [
      SidebarTransfer.split(
        sessionID: store.dragSessionID, sourceSpaceID: space, splitID: split.id),
      .folder(sessionID: store.dragSessionID, sourceSpaceID: space, folderID: folder),
      .space(sessionID: store.dragSessionID, spaceID: space),
      .tab(sessionID: UUID(), sourceSpaceID: space, tabID: tabs[0]),
      .tab(sessionID: store.dragSessionID, sourceSpaceID: UUID(), tabID: tabs[0]),
      .url(URL(string: "file:///tmp/refused")!),
    ] {
      let before = store.session
      store.sidebarDrag = refused
      #expect(!store.acceptFavoritesDrop(refused))
      #expect(store.session == before)
    }
    #expect(store.acceptFavoritesDrop(transfer(store, space, tabs[1])))
    #expect(store.session.favoritePages.map(\.tab.id) == [tabs[1]])
    #expect(store.session.selectedSpace.splits.isEmpty)
    #expect(store.session.selectedSpace.tabs.contains { $0.id == tabs[0] && $0.isPinned })
    let favorite = try #require(store.profileFavorites.first?.id)
    #expect(store.acceptFavoritesDrop(transfer(store, space, tabs[2]), before: favorite))
    #expect(store.session.favoritePages.count == 2)
    #expect(store.profileFavorites.map(\.originalURL.host) == ["tab2.example", "tab1.example"])
    try store.session.validate()
  }

  @Test func refusedDestinationsNeverDetachSplitOrConsumeFavorite() throws {
    let (store, space, tabs) = fixture()
    store.splitTabs(tabs[0], tabs[1])
    let payload = store.beginTabDrag(tabs[1], spaceID: space, fromSplitPane: true)
    let before = store.session
    #expect(!store.acceptSidebarDrop(payload, into: store.session.spaces[1].id, pinned: false))
    #expect(!store.acceptSidebarDrop(payload, into: space, pinned: true, folderID: UUID()))
    #expect(!store.acceptSidebarDrop(payload, into: space, before: UUID(), pinned: true))
    store.spaceEditor = .create
    #expect(!store.acceptSidebarDrop(payload, into: space, pinned: false))
    #expect(store.session == before)
    store.spaceEditor = nil
    #expect(store.acceptFavoritesDrop(payload))
    let favorite = try #require(store.profileFavorites.first?.id)
    let promoted = store.session
    #expect(!store.restoreFavoriteAsTab(favorite, in: space, before: UUID(), pinned: false))
    #expect(!store.restoreFavoriteAsTab(favorite, in: space, pinned: true, folderID: UUID()))
    #expect(store.session == promoted)
  }

  @Test func favoriteMovesRespectEveryDestinationAndOrder() throws {
    let (store, space, tabs) = fixture()
    #expect(store.acceptFavoritesDrop(transfer(store, space, tabs[2])))
    let favorite = try #require(store.profileFavorites.first?.id)
    let payload = ProfileFavoriteDrag(
      profileID: store.session.selectedSpace.profileID, dragSessionID: store.dragSessionID,
      favoriteID: favorite, favoriteIDs: store.profileFavorites.map(\.id))
    #expect(
      store.acceptSidebarDrop(.favorite(payload), into: space, before: tabs[3], pinned: false))
    #expect(
      store.session.selectedSpace.tabs.filter { !$0.isPinned }.map(\.id) == [tabs[2], tabs[3]])
    #expect(!store.acceptSidebarDrop(.favorite(payload), into: space, pinned: true))
    let created = store.createFolder(name: "Today", in: space, section: .today)
    let folder = try #require(created)
    #expect(store.acceptFavoritesDrop(transfer(store, space, tabs[2])))
    let next = try #require(store.profileFavorites.first?.id)
    #expect(store.restoreFavoriteAsTab(next, in: space, pinned: false, folderID: folder))
    #expect(store.session.selectedSpace.tabs.first { $0.id == tabs[2] }?.folderID == folder)
    #expect(store.acceptSidebarDrop(transfer(store, space, tabs[2]), into: space, pinned: true))
    #expect(store.session.selectedSpace.tabs.first { $0.id == tabs[2] }?.folderID == nil)
    try store.session.validate()
  }

  @Test func favoriteDropOnBackgroundSpaceKeepsCurrentSpaceSelected() throws {
    let store = BrowserStore()
    let selected = store.session.selectedSpaceID
    let profile = store.session.selectedSpace.profileID
    #expect(store.createSpace(name: "Second", sharingProfile: profile, tint: .ocean))
    let background = store.session.selectedSpaceID
    store.perform(.space(selected))
    let openedTab = store.session.open(URL(string: "https://active.example")!)
    let activeTab = try #require(openedTab)
    let created = store.session.addFavorite(
      profileID: profile, originalURL: URL(string: "https://favorite-drop.example")!)
    let favorite = try #require(created)
    let pageID = try #require(store.session.favoritePage(for: favorite)?.tab.id)
    let payload = ProfileFavoriteDrag(
      profileID: profile, dragSessionID: store.dragSessionID,
      favoriteID: favorite, favoriteIDs: store.profileFavorites.map(\.id))

    #expect(store.acceptSidebarDrop(.favorite(payload), into: background, pinned: false))
    #expect(store.session.selectedSpaceID == selected)
    #expect(store.session.selectedPage?.tab.id == activeTab)
    #expect(!store.session.favorites.contains { $0.id == favorite })
    #expect(store.session.spaces.first { $0.id == background }?.tabs.map(\.id) == [pageID])
    #expect(store.session.selectedSpace.tabs.allSatisfy { $0.id != pageID })
    try store.session.validate()
  }

  @Test func crossProfileFavoriteDropExplainsTheBoundary() throws {
    let store = BrowserStore()
    let source = store.session.selectedSpace
    let other = try #require(store.session.spaces.first { $0.id != source.id })
    let created = store.session.addFavorite(
      profileID: source.profileID, originalURL: URL(string: "https://favorite.example")!)
    let favorite = try #require(created)
    let payload = ProfileFavoriteDrag(
      profileID: source.profileID, dragSessionID: store.dragSessionID,
      favoriteID: favorite, favoriteIDs: store.profileFavorites.map(\.id))
    let before = store.session

    #expect(!store.acceptSidebarDrop(.favorite(payload), into: other.id))
    #expect(store.session == before)
    #expect(store.sidebarNotice == "Favorites can move only between spaces sharing a profile.")
    #expect(store.acceptSidebarDrop(.favorite(payload), into: source.id, pinned: false))
    #expect(store.sidebarNotice == nil)
    try store.session.validate()
  }

  @Test func stackMovesPreserveLayoutOrderAndFolderMembership() throws {
    let (store, space, tabs) = fixture()
    store.splitTabs(tabs[0], tabs[1])
    store.applySplitLayout(.rows)
    let split = try #require(store.session.selectedSpace.splits.first)
    let payload = SidebarTransfer.split(
      sessionID: store.dragSessionID, sourceSpaceID: space, splitID: split.id)
    #expect(store.acceptSidebarDrop(payload, into: space, before: tabs[3], pinned: false))
    #expect(store.session.selectedSpace.splits == [split])
    #expect(
      store.session.selectedSpace.tabs.filter { !$0.isPinned }.map(\.id) == [
        tabs[0], tabs[1], tabs[3],
      ])
    let created = store.createFolder(name: "Stack", in: space)
    let folder = try #require(created)
    #expect(store.acceptSidebarDrop(payload, into: space, pinned: true, folderID: folder))
    #expect(
      store.session.selectedSpace.tabs.filter { $0.folderID == folder }.map(\.id) == split.tabIDs)
    #expect(store.session.selectedSpace.splits == [split])
    #expect(store.acceptSidebarDrop(transfer(store, space, tabs[1]), into: space, pinned: true))
    #expect(store.session.selectedSpace.splits.isEmpty)
    #expect(store.session.selectedSpace.tabs.first { $0.id == tabs[1] }?.folderID == nil)
    try store.session.validate()
  }

  @Test func splitMemberCurrentFolderActionPreservesSplit() throws {
    let store = BrowserStore()
    let space = store.session.selectedSpaceID
    let openedFirst = store.session.open(URL(string: "https://first.example")!)
    let first = try #require(openedFirst)
    let openedSecond = store.session.open(URL(string: "https://second.example")!)
    let second = try #require(openedSecond)
    store.togglePin(first)
    store.togglePin(second)
    let folder = try #require(store.createFolder(name: "Projects", in: space))
    #expect(store.moveTab(first, from: space, to: space, folderID: folder))
    #expect(store.moveTab(second, from: space, to: space, folderID: folder))
    store.splitTabs(first, second)
    let before = store.session
    #expect(before.selectedSpace.splits.count == 1)

    #expect(!store.moveSplitMemberToFolder(second, in: space, folderID: folder))
    #expect(store.session == before)

    let other = try #require(store.createFolder(name: "Other", in: space))
    #expect(store.moveSplitMemberToFolder(second, in: space, folderID: other))
    #expect(store.session.selectedSpace.splits.isEmpty)
    #expect(store.session.selectedSpace.tabs.first { $0.id == second }?.folderID == other)
    try store.session.validate()
  }

  @Test func folderCreationMovesPagesInOrderAndRemovalPromotesThem() throws {
    let (store, space, tabs) = fixture()
    let payload = transfer(store, space, tabs[3])
    let created = store.createFolderFromDrop(payload, onto: tabs[0], name: "Projects")
    let folder = try #require(created)
    #expect(
      store.session.selectedSpace.tabs.filter { $0.folderID == folder }.map(\.id) == [
        tabs[0], tabs[3],
      ])
    #expect(
      store.acceptSidebarDrop(
        transfer(store, space, tabs[1]), into: space, pinned: true, folderID: folder))
    #expect(store.removeFolder(folder, in: space))
    #expect(store.session.selectedSpace.tabs.allSatisfy { $0.folderID == nil })
    #expect(store.createFolderFromDrop(payload, onto: tabs[3], name: "Invalid") == nil)
    try store.session.validate()
  }

  @Test func movingOutsideFolderKeepsTheTabsOriginalSection() throws {
    let (store, space, tabs) = fixture()
    let today = try #require(store.createFolder(name: "Today", in: space, section: .today))
    #expect(store.moveTab(tabs[3], from: space, to: space, folderID: today))
    #expect(store.moveTabOutsideFolder(tabs[3], in: space))
    let todayTab = try #require(store.session.selectedSpace.tabs.first { $0.id == tabs[3] })
    #expect(todayTab.folderID == nil)
    #expect(!todayTab.isPinned)

    let pinned = try #require(store.createFolder(name: "Pinned", in: space, section: .pinned))
    #expect(store.moveTab(tabs[0], from: space, to: space, folderID: pinned))
    #expect(store.moveTabOutsideFolder(tabs[0], in: space))
    let pinnedTab = try #require(store.session.selectedSpace.tabs.first { $0.id == tabs[0] })
    #expect(pinnedTab.folderID == nil)
    #expect(pinnedTab.isPinned)
    try store.session.validate()
  }

  @Test func fullFavoritesAndInvalidURLsLeaveSessionUntouched() throws {
    let (store, space, tabs) = fixture()
    for index in 0..<BrowserSession.maximumFavoritesPerProfile {
      _ = store.session.addFavorite(
        profileID: store.session.selectedSpace.profileID,
        originalURL: URL(string: "https://favorite\(index).example")!)
    }
    let before = store.session
    #expect(!store.acceptFavoritesDrop(transfer(store, space, tabs[0])))
    #expect(!store.acceptFavoritesDrop(.url(URL(string: "https://extra.example")!)))
    #expect(!store.acceptSidebarDrop(.url(URL(string: "file:///tmp/refused")!), into: space))
    #expect(
      !store.acceptSidebarDrop(
        .url(URL(string: "https://valid.example")!), into: space, folderID: UUID()))
    #expect(store.session == before)
  }

  @Test func urlDropOnBackgroundSpaceOpensThereWithoutSwitchingSpaces() throws {
    let store = BrowserStore()
    let selected = store.session.selectedSpaceID
    let background = try #require(store.session.spaces.first { $0.id != selected })
    let originalTabs = background.tabs.map(\.id)
    let url = try #require(URL(string: "https://background-drop.example/path"))

    #expect(store.acceptSidebarDrop(.url(url), into: background.id))
    #expect(store.session.selectedSpaceID == selected)
    let updated = try #require(store.session.spaces.first { $0.id == background.id })
    #expect(updated.tabs.count == originalTabs.count + 1)
    #expect(updated.tabs.last?.url == url)
    #expect(store.session.selectedSpace.tabs.allSatisfy { $0.url != url })
    try store.session.validate()
  }
}
