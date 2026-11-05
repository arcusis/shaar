// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser
@testable import BrowserCore

@Suite @MainActor
struct CommandNewTabTests {
  @Test func commandReturnOpensFavoriteInAnOrdinaryNewTab() throws {
    let store = BrowserStore()
    let url = URL(string: "https://favorite.example/path")!
    let profileID = store.session.selectedSpace.profileID
    let addedFavoriteID = store.session.addFavorite(profileID: profileID, originalURL: url)
    let favoriteID = try #require(addedFavoriteID)
    store.showCommand()
    store.commandQuery = "favorite.example"
    let index = try #require(
      store.results.firstIndex { $0.action == .favorite(profile: profileID, id: favoriteID) })
    store.moveCommandSelection(by: index)
    #expect(store.selectedCommandResult?.action == .favorite(profile: profileID, id: favoriteID))

    CommandPanel(store: store, resultsHeight: 320).acceptCommandInNewTab()

    #expect(store.session.selectedSpace.tabs.count == 1)
    #expect(store.session.selectedSpace.selectedTab?.url == url)
    #expect(store.session.favorites.contains { $0.id == favoriteID })
    #expect(!store.commandIsOpen)
  }
}
