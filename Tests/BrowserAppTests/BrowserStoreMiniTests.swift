// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserStoreMiniTests {
  @Test func rejectsNonWebAndUnknownMiniDestinationsWithoutChangingTheSession() throws {
    let store = BrowserStore()
    store.perform(.open(try #require(URL(string: "https://current.example/page"))))
    let space = store.session.selectedSpace
    let before = store.session

    #expect(
      !store.receiveMiniTab(
        BrowserTab(url: try #require(URL(string: "file:///tmp/page.html"))),
        in: space.id, profileID: space.profileID, archive: false))
    #expect(
      !store.receiveMiniTab(
        BrowserTab(url: try #require(URL(string: "https://mini.example/page"))),
        in: UUID(), profileID: space.profileID, archive: true))
    #expect(store.session == before)
  }
}
