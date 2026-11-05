// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@MainActor @Test func privateSelectedFavoriteTracksTheSiteControlsOrigin() throws {
  let session = try BrowserSession.privateWindow(
    sourceProfileID: UUID(), firstTabID: UUID())
  let store = BrowserStore(privateSession: session)
  let firstURL = try #require(URL(string: "https://first.example/path"))
  let nextURL = try #require(URL(string: "https://next.example/path"))
  store.perform(.open(firstURL))
  #expect(store.addCurrentPageAsFavorite())
  let selectedID = try #require(store.session.selectedPage?.tab.id)
  #expect(store.selectedTab?.url == firstURL.absoluteString)

  store.nativeTabChanged(selectedID, url: nextURL, title: "Next")
  #expect(store.session.selectedPage?.tab.url == nextURL)
  #expect(store.selectedTab?.url == nextURL.absoluteString)
}
