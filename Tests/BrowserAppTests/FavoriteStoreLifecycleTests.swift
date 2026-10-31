// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct FavoriteStoreLifecycleTests {
  @Test func promotionReusesSelectedTabAndNativeCloseRemovesOnlyLocalPage() throws {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://fallback.example")!))
    let fallbackID = try #require(store.session.selectedPage?.tab.id)
    store.perform(.open(URL(string: "https://favorite.example/start")!))
    let promotedID = try #require(store.session.selectedPage?.tab.id)
    let profileID = store.session.selectedSpace.profileID

    #expect(store.canFavoriteCurrentPage)
    #expect(store.addCurrentPageAsFavorite())
    let favorite = try #require(store.session.selectedFavorite)
    let page = try #require(store.session.selectedPage?.tab)
    #expect(page.id == promotedID)
    #expect(!store.canFavoriteCurrentPage)
    #expect(!store.addCurrentPageAsFavorite())
    #expect(store.session.spaces.flatMap(\.tabs).map(\.id) == [fallbackID])

    var requestedClose: UUID?
    store.onCloseTab = { requestedClose = $0 }
    store.closeCurrentPage()
    #expect(requestedClose == promotedID)
    #expect(store.session.favoritePages.contains { $0.tab.id == promotedID })

    store.nativeTabClosed(promotedID)
    #expect(store.session.favorites.contains(where: { $0.id == favorite.id }))
    #expect(store.session.favoritePages.isEmpty)
    #expect(store.session.selectedPage?.tab.id == fallbackID)
    #expect(!store.nativeFavoriteActivated(promotedID, profileID: profileID))
    var navigation: (UUID, UUID, URL)?
    store.onNavigatePage = { tab, profile, url in
      navigation = (tab, profile, url)
      return store.session.favoritePages.contains {
        $0.favoriteID == favorite.id && $0.tab.id == tab
      }
    }
    #expect(store.resetFavorite(favorite.id))
    let reopenedPage = try #require(store.session.selectedPage?.tab)
    #expect(reopenedPage.id != promotedID)
    #expect(reopenedPage.url == favorite.originalURL)
    #expect(navigation?.0 == reopenedPage.id)
    #expect(navigation?.1 == profileID)
    #expect(navigation?.2 == favorite.originalURL)
    #expect(store.session.favorites.first?.originalURL == favorite.originalURL)
    store.nativeFavoritePageChanged(
      promotedID, profileID: profileID, url: URL(string: "https://stale.example")!, title: "Stale")
    #expect(store.session.selectedPage?.tab.id == reopenedPage.id)
    #expect(store.session.selectedPage?.tab.url == favorite.originalURL)
  }

  @Test func favoriteCallbacksAndActionsRejectForeignOrStaleIdentities() throws {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://favorite.example/original")!))
    let profileID = store.session.selectedSpace.profileID
    #expect(store.addCurrentPageAsFavorite())
    let favorite = try #require(store.session.selectedFavorite)
    let page = try #require(store.session.favoritePages.first)
    let originalURL = favorite.originalURL

    store.nativeFavoritePageChanged(
      page.tab.id, profileID: UUID(), url: URL(string: "https://foreign.example")!, title: "Foreign"
    )
    #expect(store.session.favoritePages.first?.tab.url == originalURL)
    store.nativeFavoritePageChanged(
      page.tab.id, profileID: profileID,
      url: URL(string: "https://favorite.example/current")!, title: "Current")
    #expect(
      store.session.favoritePages.first?.tab.url.absoluteString
        == "https://favorite.example/current")
    #expect(store.session.favorites.first?.originalURL == originalURL)

    #expect(!store.selectFavorite(UUID()))
    #expect(!store.removeFavorite(UUID()))
    #expect(!store.nativeFavoriteActivated(page.tab.id, profileID: UUID()))

    var navigation: (UUID, UUID, URL)?
    store.onNavigatePage = { tab, profile, url in
      navigation = (tab, profile, url)
      store.nativeFavoritePageChanged(tab, profileID: profile, url: url, title: "Original")
      return true
    }
    #expect(store.resetFavorite(favorite.id))
    #expect(navigation?.0 == page.tab.id)
    #expect(navigation?.1 == profileID)
    #expect(navigation?.2 == originalURL)
    #expect(store.session.favoritePages.first?.tab.url == originalURL)
    #expect(store.session.favorites.first?.originalURL == originalURL)

    #expect(store.removeFavorite(favorite.id))
    #expect(store.session.favorites.isEmpty)
    #expect(store.session.favoritePages.isEmpty)
    #expect(store.session.spaces.flatMap(\.tabs).contains { $0.id == page.tab.id })
    #expect(!store.resetFavorite(favorite.id))
  }

  @Test func favoriteOpenerCreatesTabInMatchingProfileSpace() throws {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://favorite.example")!))
    let profileID = store.session.selectedSpace.profileID
    #expect(store.addCurrentPageAsFavorite())
    let favoritePage = try #require(store.session.favoritePages.first)
    let currentSpaceID = store.session.selectedSpaceID
    #expect(store.createSpace(name: "Second", sharingProfile: profileID, tint: .ocean))
    let otherSpaceID = try #require(store.session.spaces.first { $0.name == "Second" }?.id)
    store.perform(.space(currentSpaceID))

    let popup = BrowserTab(url: URL(string: "https://popup.example")!)
    #expect(
      store.nativeTabOpened(
        popup, profileID: profileID, openerID: favoritePage.tab.id, foreground: false))
    #expect(
      store.session.spaces.first(where: { $0.id == currentSpaceID })?.tabs.contains {
        $0.id == popup.id
      } == true)
    #expect(store.session.selectedSpaceID == currentSpaceID)
    #expect(store.session.spaces.first(where: { $0.id == otherSpaceID })?.tabs.isEmpty == true)
  }
}
