// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import BrowserCore

@Test func favoriteSearchMatchesSavedAndLiveMetadataOnceAcrossSpaces() throws {
  var session = BrowserSession.fresh()
  let profileID = session.selectedSpace.profileID
  let addedFavoriteID = session.addFavorite(
    profileID: profileID,
    originalURL: URL(string: "https://saved.example/original-token")!,
    title: "Saved favorite title")
  let favoriteID = try #require(addedFavoriteID)
  let pageID = try #require(session.favoritePages.first { $0.favoriteID == favoriteID }?.tab.id)
  let didUpdatePage = session.updateFavoritePage(
    favoriteID, url: URL(string: "https://live.example/current-token")!,
    title: "Live favorite title")
  #expect(didUpdatePage)
  let addedSpaceID = session.addSpace(name: "Shared", sharingProfile: profileID)
  let secondSpaceID = try #require(addedSpaceID)

  for query in [
    "Saved favorite title", "original-token", "Live favorite title", "current-token",
  ] {
    let favoriteResults = CommandSearch.results(for: query, in: session).filter {
      $0.action == .favorite(profile: profileID, id: favoriteID)
    }
    #expect(favoriteResults.count == 1)
  }

  let urlResults = CommandSearch.results(
    for: "https://live.example/current-token", in: session)
  #expect(urlResults.first?.action == .favorite(profile: profileID, id: favoriteID))
  #expect(urlResults.last?.action == .open(URL(string: "https://live.example/current-token")!))
  #expect(session.selectedSpaceID == secondSpaceID)
  #expect(session.favoritePages.first?.tab.id == pageID)
}

@Test func closedFavoriteDefinitionIsSearchableAndFavoritesPrecedeOrdinaryLimit() throws {
  let profile = BrowserProfile(name: "Personal")
  let foreignProfile = BrowserProfile(name: "Work")
  let selectedID = UUID()
  let selectedSpace = BrowserSpace(
    id: selectedID, profileID: profile.id, name: "Main", symbol: "house", tint: .ocean,
    tabs: (0..<12).map { index in
      BrowserTab(
        url: URL(string: "https://ordinary.example/needle-\(index)")!, title: "needle \(index)")
    })
  let favorites =
    (0..<12).map { index in
      BrowserFavorite(
        id: stableID(index + 100), profileID: profile.id,
        originalURL: URL(string: "https://favorite.example/needle-\(index)")!,
        title: "needle favorite \(index)")
    } + [
      BrowserFavorite(
        id: stableID(900), profileID: foreignProfile.id,
        originalURL: URL(string: "https://foreign.example/needle")!, title: "needle foreign")
    ]
  let foreignSpace = BrowserSpace(
    profileID: foreignProfile.id, name: "Work", symbol: "briefcase", tint: .rose)
  let session = try BrowserSession(
    profiles: [profile, foreignProfile], spaces: [selectedSpace, foreignSpace],
    selectedSpaceID: selectedID, favorites: favorites)

  let results = CommandSearch.results(for: "needle", in: session)
  #expect(results.count == 10)
  #expect(
    results.prefix(9).map(\.action)
      == favorites.prefix(9).map { .favorite(profile: profile.id, id: $0.id) })
  #expect(results.last?.action == .open(searchURL("needle")))
  #expect(
    !results.contains { $0.action == .favorite(profile: foreignProfile.id, id: stableID(900)) })

  let closedMatch = CommandSearch.results(for: "needle favorite 11", in: session)
  #expect(closedMatch.first?.action == .favorite(profile: profile.id, id: favorites[11].id))
}

private func searchURL(_ query: String) -> URL {
  var components = URLComponents(string: "https://www.google.com/search")!
  components.queryItems = [URLQueryItem(name: "q", value: query)]
  return components.url!
}

private func stableID(_ suffix: Int) -> UUID {
  UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", suffix))!
}
