// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@Test func pinnedAndTodayFoldersPersistAndLegacyFoldersDefaultPinned() throws {
  var session = BrowserSession.fresh()
  let space = session.selectedSpaceID
  let pinnedTab = session.open(URL(string: "https://pinned.example")!)!
  let todayTab = session.open(URL(string: "https://today.example")!)!
  let pinnedFolder = session.addFolder(name: "Pinned", in: space, section: .pinned)!
  let todayFolder = session.addFolder(name: "Today", in: space, section: .today)!
  let movedPinned = session.moveTab(pinnedTab, from: space, to: space, folderID: pinnedFolder)
  let movedToday = session.moveTab(todayTab, from: space, to: space, folderID: todayFolder)
  #expect(movedPinned)
  #expect(movedToday)
  #expect(session.selectedSpace.tabs.first { $0.id == pinnedTab }?.isPinned == true)
  #expect(session.selectedSpace.tabs.first { $0.id == todayTab }?.isPinned == false)
  #expect(session.selectedSpace.items(isPinned: true).count == 2)
  #expect(session.selectedSpace.items(isPinned: false).count == 2)
  #expect(
    try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(session)) == session)

  let oldFolder = try JSONDecoder().decode(
    BrowserFolder.self,
    from: Data(
      "{\"id\":\"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA\",\"name\":\"Legacy\",\"isCollapsed\":false}"
        .utf8))
  #expect(oldFolder.isPinned)
}

@Test func clearTodayTabsKeepsPinnedFoldersFavoritesAndRecoveryEntries() throws {
  var session = BrowserSession.fresh()
  let space = session.selectedSpaceID
  let pinned = session.open(URL(string: "https://pinned.example")!)!
  session.togglePin(pinned)
  let today = session.open(URL(string: "https://today.example")!)!
  let folder = session.addFolder(name: "Pinned folder", in: space)!
  let folderTab = session.open(URL(string: "https://folder.example")!)!
  _ = session.moveTab(folderTab, from: space, to: space, folderID: folder)
  let favorite = session.addFavorite(
    profileID: session.selectedSpace.profileID,
    originalURL: URL(string: "https://favorite.example")!, title: "Favorite")
  #expect(favorite != nil)
  for tab in session.selectedSpace.tabs where !tab.isPinned { session.closeTab(tab.id) }
  #expect(Set(session.selectedSpace.tabs.map(\.id)) == Set([pinned, folderTab]))
  #expect(session.selectedSpace.folders.map(\.id) == [folder])
  #expect(session.favorites.count == 1)
  #expect(session.closedTabs.contains { $0.id == today })
  try session.validate()
}

@Test func favoritePagesRestoreIntoEitherSectionAndPersistAsTabs() throws {
  var session = BrowserSession.fresh()
  let space = session.selectedSpaceID
  for (host, pinned) in [("pinned.example", true), ("today.example", false)] {
    let profileID = session.selectedSpace.profileID
    let addedFavorite = session.addFavorite(
      profileID: profileID, originalURL: URL(string: "https://\(host)")!, title: host)
    let favorite = try #require(addedFavorite)
    let pageID = try #require(session.favoritePages.first { $0.favoriteID == favorite }?.tab.id)
    let selected = session.selectFavorite(favorite, in: space)
    let removed = session.removeFavorite(favorite, disposition: .preserveAsTab)
    let moved = !pinned || session.moveTab(pageID, from: space, to: space, pinned: true)
    #expect(selected)
    #expect(removed)
    #expect(moved)
    #expect(session.selectedSpace.tabs.first { $0.id == pageID }?.isPinned == pinned)
    #expect(!session.favorites.contains { $0.id == favorite })
  }
  try session.validate()
  #expect(
    try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(session)) == session)
}
