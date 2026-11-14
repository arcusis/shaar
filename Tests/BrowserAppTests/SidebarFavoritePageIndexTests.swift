// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Test func sidebarFavoritePageLookupFocusedBenchmark() {
  let profileID = UUID()
  let favorites = (0..<1_000).map { index in
    BrowserFavorite(
      profileID: profileID, originalURL: URL(string: "https://example.test/\(index)")!,
      title: "Favorite \(index)")
  }
  let pages = favorites.map { favorite in
    BrowserFavoritePage(
      favoriteID: favorite.id,
      tab: BrowserTab(url: favorite.originalURL, title: favorite.title))
  }
  var pageIDs: [UUID?] = []

  let start = ContinuousClock.now
  for _ in 0..<10 {
    pageIDs = favorites.map { favorite in
      pages.first { $0.favoriteID == favorite.id }?.tab.id
    }
  }
  print("sidebarFavoritePageLookupFocusedBenchmark: \(start.duration(to: .now))")
  #expect(pageIDs.count == favorites.count)

  var indexedPageIDs: [UUID?] = []
  let indexedStart = ContinuousClock.now
  for _ in 0..<10 {
    let pageIndex = FavoritePageIndex(pages)
    indexedPageIDs = favorites.map { favorite in pageIndex.page(for: favorite.id)?.tab.id }
  }
  print("sidebarFavoritePageIndexFocusedBenchmark: \(indexedStart.duration(to: .now))")
  #expect(indexedPageIDs == pageIDs)
}

@Test func favoritePageIndexPreservesFirstMatchAndReturnsNilForMissingPages() {
  let favoriteID = UUID()
  let first = BrowserFavoritePage(
    favoriteID: favoriteID, tab: BrowserTab(url: URL(string: "https://first.example")!))
  let duplicate = BrowserFavoritePage(
    favoriteID: favoriteID, tab: BrowserTab(url: URL(string: "https://duplicate.example")!))
  let index = FavoritePageIndex([first, duplicate])

  #expect(index.page(for: favoriteID) == first)
  #expect(index.page(for: UUID()) == nil)
}
