// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct FavoriteWorkspaceStoreTests {
  @Test func favoritePagesStayWindowLocalAndSharedRemovalPreservesPeerPage() throws {
    let manager = try BrowserWorkspaceStore(initialSession: fixture())
    let firstID = manager.workspace.windows[0].id
    let secondID = try manager.newWindow(from: firstID)
    let first = try #require(manager.stores[firstID])
    let second = try #require(manager.stores[secondID])
    let favorite = try #require(first.session.favorites.first)
    let firstPage = try #require(first.session.favoritePages.first)
    let secondPage = try #require(second.session.favoritePages.first)
    #expect(firstPage.favoriteID == secondPage.favoriteID)
    #expect(firstPage.tab.id != secondPage.tab.id)

    first.nativeFavoritePageChanged(
      firstPage.tab.id, profileID: favorite.profileID,
      url: URL(string: "https://favorite.example/first-window")!, title: "First")
    #expect(
      first.session.favoritePages.first?.tab.url.absoluteString
        == "https://favorite.example/first-window")
    #expect(second.session.favoritePages.first?.tab.url == favorite.originalURL)
    #expect(manager.workspace.catalog.favorites.first?.originalURL == favorite.originalURL)

    #expect(first.removeFavorite(favorite.id))
    #expect(first.session.favorites.count == 1 && first.session.favoritePages.count == 1)
    #expect(second.session.favorites.count == 1 && second.session.favoritePages.count == 1)
    #expect(
      second.session.spaces.flatMap(\.tabs).contains {
        $0.id == secondPage.tab.id && $0.url.absoluteString == "https://favorite.example"
      })
    #expect(
      first.session.spaces.flatMap(\.tabs).contains {
        $0.id == firstPage.tab.id
          && $0.url.absoluteString == "https://favorite.example/first-window"
      })
  }

  @Test func favoriteSelectionUsesExistingPageOnlyInMatchingSpaceAndProfile() throws {
    let manager = try BrowserWorkspaceStore(initialSession: fixture())
    let windowID = manager.workspace.windows[0].id
    let store = try #require(manager.stores[windowID])
    let profileID = store.session.selectedSpace.profileID
    let favorite = try #require(store.session.favorites.first)
    let firstSpaceID = store.session.selectedSpaceID
    #expect(store.createSpace(name: "Another", sharingProfile: profileID, tint: .ocean))
    let secondSpaceID = store.session.selectedSpaceID
    let pageID = try #require(store.session.favoritePages.first?.tab.id)

    store.perform(.tab(space: firstSpaceID, tab: pageID))
    #expect(store.session.selectedSpaceID == firstSpaceID)
    #expect(store.session.selectedPage?.tab.id == pageID)
    #expect(store.session.favoritePages.count == 2)

    let foreignSpaceID = try #require(
      store.session.spaces.first(where: { $0.profileID != profileID })?.id)
    let foreignProfileID = try #require(
      store.session.spaces.first(where: { $0.id == foreignSpaceID })?.profileID)
    #expect(!store.nativeFavoriteActivated(pageID, profileID: foreignProfileID))
    #expect(store.session.favorites.contains { $0.id == favorite.id })
    #expect(store.session.selectedSpaceID == firstSpaceID)
    #expect(foreignSpaceID != secondSpaceID)
  }

  @Test func explicitFavoriteTabSelectionMayCrossProfilesButRejectsWrongOwnerSpace() throws {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://favorite.example")!))
    let favoriteProfileID = store.session.selectedSpace.profileID
    let favoriteSpaceID = store.session.selectedSpaceID
    #expect(store.addCurrentPageAsFavorite())
    let favoritePageID = try #require(store.session.favoritePages.first?.tab.id)
    #expect(store.createSpace(name: "Other profile", sharingProfile: nil, tint: .rose))
    let otherSpaceID = store.session.selectedSpaceID
    #expect(store.session.selectedSpace.profileID != favoriteProfileID)

    store.perform(.tab(space: favoriteSpaceID, tab: favoritePageID))
    #expect(store.session.selectedSpaceID == favoriteSpaceID)
    #expect(store.session.selectedPage?.tab.id == favoritePageID)
    #expect(store.session.selectedFavorite?.profileID == favoriteProfileID)

    store.perform(.space(otherSpaceID))
    store.perform(.tab(space: otherSpaceID, tab: favoritePageID))
    #expect(store.session.selectedSpaceID == otherSpaceID)
    #expect(store.session.selectedPage == nil)
  }

  @Test func openerSpaceResolutionPrefersOrdinaryOwnerAndThenFavoriteRules() throws {
    var session = BrowserSession.fresh()
    let profileID = session.selectedSpace.profileID
    let ordinarySpaceID = session.selectedSpaceID
    let ordinaryIDValue = session.open(URL(string: "https://ordinary.example")!)
    let ordinaryID = try #require(ordinaryIDValue)
    let selectedSpaceValue = session.addSpace(
      name: "Second shared space", sharingProfile: profileID)
    let selectedSpaceID = try #require(selectedSpaceValue)
    session.selectSpace(selectedSpaceID)
    #expect(
      NativeBrowserHost.openerSpaceID(
        in: session, openerID: ordinaryID, profileID: profileID) == ordinarySpaceID)

    let favoriteIDValue = session.addFavorite(
      profileID: profileID, originalURL: URL(string: "https://favorite.example")!)
    let favoriteID = try #require(favoriteIDValue)
    let favoritePageID = try #require(
      session.favoritePages.first(where: { $0.favoriteID == favoriteID })?.tab.id)
    #expect(
      NativeBrowserHost.openerSpaceID(
        in: session, openerID: favoritePageID, profileID: profileID) == selectedSpaceID)

    let selectedFavorite = session.selectFavorite(favoriteID, in: ordinarySpaceID)
    #expect(selectedFavorite)
    let otherProfileSpaceValue = session.addSpace(name: "Separate profile")
    let otherProfileSpaceID = try #require(otherProfileSpaceValue)
    session.selectSpace(otherProfileSpaceID)
    #expect(
      NativeBrowserHost.openerSpaceID(
        in: session, openerID: favoritePageID, profileID: profileID) == ordinarySpaceID)
  }

  @Test func lastProfileSpaceImpactCountsFavoritePagesAcrossWindows() throws {
    var session = BrowserSession.fresh()
    let profileID = session.selectedSpace.profileID
    let favoriteIDValue = session.addFavorite(
      profileID: profileID, originalURL: URL(string: "https://favorite.example")!)
    let favoriteID = try #require(favoriteIDValue)
    let otherProfileSpaceID = session.addSpace(name: "Other profile", sharingProfile: nil)
    #expect(otherProfileSpaceID != nil)
    let manager = try BrowserWorkspaceStore(initialSession: session)
    let firstID = manager.workspace.windows[0].id
    let secondID = try manager.newWindow(from: firstID)
    let favoriteSpace = try #require(
      manager.stores[firstID]?.session.spaces.first(where: { $0.profileID == profileID })?.id)
    let impact = try #require(manager.stores[firstID]).spaceRemovalImpact(favoriteSpace)
    #expect(impact.favoritePages == 2)
    #expect(impact.message.contains("2 Favorite pages"))
    #expect(manager.stores[secondID]?.session.favorites.contains { $0.id == favoriteID } == true)
  }

  @Test func movingFavoriteUpdatesSharedCatalogWithoutReplacingLivePages() throws {
    let manager = try BrowserWorkspaceStore(initialSession: fixture())
    let firstID = manager.workspace.windows[0].id
    let secondID = try manager.newWindow(from: firstID)
    let first = try #require(manager.stores[firstID])
    let second = try #require(manager.stores[secondID])
    let originalPageIDs = Dictionary(
      uniqueKeysWithValues: first.session.favoritePages.map { ($0.favoriteID, $0.tab.id) })
    let favorites = first.profileFavorites
    let firstFavorite = favorites[0]
    let secondFavorite = favorites[1]

    #expect(first.moveFavorite(secondFavorite.id, before: firstFavorite.id))
    #expect(first.profileFavorites.map(\.id) == [secondFavorite.id, firstFavorite.id])
    #expect(second.profileFavorites.map(\.id) == [secondFavorite.id, firstFavorite.id])
    #expect(
      Dictionary(
        uniqueKeysWithValues: first.session.favoritePages.map {
          ($0.favoriteID, $0.tab.id)
        }) == originalPageIDs)
    #expect(second.session.favoritePages.count == 2)
  }

  private func fixture() -> BrowserSession {
    var session = BrowserSession.fresh()
    _ = session.addFavorite(
      profileID: session.selectedSpace.profileID,
      originalURL: URL(string: "https://favorite.example")!, title: "Favorite")
    _ = session.addFavorite(
      profileID: session.selectedSpace.profileID,
      originalURL: URL(string: "https://other.example")!, title: "Other")
    return session
  }
}
