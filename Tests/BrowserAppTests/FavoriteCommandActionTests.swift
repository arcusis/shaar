// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct FavoriteCommandActionTests {
  @Test func openCommandSelectsExistingFavoritePageInCurrentSharedProfileSpace() throws {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://favorite.example/start")!))
    let pageID = try #require(store.session.selectedPage?.tab.id)
    let profileID = store.session.selectedSpace.profileID
    #expect(store.addCurrentPageAsFavorite())
    let favoriteID = try #require(store.session.favorites.first?.id)
    let originalSpaceID = store.session.selectedSpaceID

    #expect(store.createSpace(name: "Shared", sharingProfile: profileID, tint: .forest))
    let sharedSpaceID = try #require(store.session.spaces.first { $0.name == "Shared" }?.id)
    store.perform(.space(sharedSpaceID))
    store.showCommand()
    store.perform(.favorite(profile: profileID, id: favoriteID))

    #expect(store.session.selectedSpaceID == sharedSpaceID)
    #expect(store.session.selectedPage?.tab.id == pageID)
    #expect(store.session.favoritePages.count == 1)
    #expect(!store.session.spaces.flatMap(\.tabs).contains { $0.id == pageID })
    #expect(!store.commandIsOpen)
    #expect(store.session.selectedSpaceID != originalSpaceID)
  }

  @Test func commandReopensClosedFavoritePageWithoutOrdinaryDuplicateOrSpaceChange() throws {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://favorite.example/start")!))
    let oldPageID = try #require(store.session.selectedPage?.tab.id)
    let profileID = store.session.selectedSpace.profileID
    let spaceID = store.session.selectedSpaceID
    #expect(store.addCurrentPageAsFavorite())
    let favoriteID = try #require(store.session.favorites.first?.id)
    store.nativeTabClosed(oldPageID)
    #expect(store.session.favoritePages.isEmpty)

    store.showCommand()
    store.perform(.favorite(profile: profileID, id: favoriteID))

    let reopenedID = try #require(store.session.selectedPage?.tab.id)
    #expect(reopenedID != oldPageID)
    #expect(store.session.selectedSpaceID == spaceID)
    #expect(store.session.favoritePages.count == 1)
    #expect(store.session.favoritePages.first?.tab.id == reopenedID)
    #expect(!store.session.spaces.flatMap(\.tabs).contains { $0.id == reopenedID })
  }

  @Test func staleForeignAndSheetBlockedFavoriteActionsDoNotChangeSelection() throws {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://personal.example")!))
    let personalProfileID = store.session.selectedSpace.profileID
    #expect(store.addCurrentPageAsFavorite())
    let personalFavoriteID = try #require(store.session.favorites.first?.id)
    let personalPageID = try #require(store.session.selectedPage?.tab.id)
    let workSpaceID = try #require(
      store.session.spaces.first { $0.profileID != personalProfileID }?.id)
    let workProfileID = try #require(
      store.session.spaces.first { $0.id == workSpaceID }?.profileID)

    store.perform(.space(workSpaceID))
    store.commandIsOpen = true
    store.perform(.favorite(profile: personalProfileID, id: personalFavoriteID))
    #expect(store.session.selectedSpaceID == workSpaceID)
    #expect(store.session.selectedPage == nil)
    #expect(store.commandIsOpen)
    store.perform(.favorite(profile: workProfileID, id: personalFavoriteID))
    #expect(store.session.selectedSpaceID == workSpaceID)
    #expect(store.session.selectedPage == nil)
    #expect(store.commandIsOpen)

    store.commandIsOpen = false
    store.perform(.space(store.session.spaces.first { $0.profileID == personalProfileID }!.id))
    #expect(store.removeFavorite(personalFavoriteID))
    store.showCommand()
    store.perform(.favorite(profile: personalProfileID, id: personalFavoriteID))
    #expect(store.session.selectedPage?.tab.id == personalPageID)
    #expect(store.commandIsOpen)

    store.commandIsOpen = false
    store.perform(.space(workSpaceID))
    store.perform(.open(URL(string: "https://work.example")!))
    let workPageID = try #require(store.session.selectedPage?.tab.id)
    #expect(store.addCurrentPageAsFavorite())
    let workFavoriteID = try #require(
      store.session.favorites.first { $0.profileID == workProfileID }?.id)
    store.showCommand()
    store.sheet = .downloads(profileID: workProfileID)
    store.perform(.favorite(profile: workProfileID, id: workFavoriteID))
    #expect(store.session.selectedPage?.tab.id == workPageID)
    #expect(store.sheet != nil)
    #expect(store.commandIsOpen)
  }
}
