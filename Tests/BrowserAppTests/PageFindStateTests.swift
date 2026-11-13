// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct PageFindStateTests {
  @Test func documentIdentityIgnoresFragmentsButIncludesQueryAndPath() throws {
    let originalURL = URL(string: "https://find.example/article?lang=en#intro")!
    var session = BrowserSession.fresh()
    let tabID = session.open(originalURL)!
    let state = PageFindState(
      profileID: session.selectedSpace.profileID, tabID: tabID, pageURL: originalURL)

    let store = BrowserStore(session: session)
    store.nativeTabChanged(
      tabID, url: URL(string: "https://find.example/article?lang=en#details")!, title: "Article")
    #expect(state.matches(store.session))

    let queryStore = BrowserStore(session: session)
    queryStore.nativeTabChanged(
      tabID, url: URL(string: "https://find.example/article?lang=fr#intro")!, title: "Article")
    #expect(!state.matches(queryStore.session))

    let pathStore = BrowserStore(session: session)
    pathStore.nativeTabChanged(
      tabID, url: URL(string: "https://find.example/other?lang=en#intro")!, title: "Article")
    #expect(!state.matches(pathStore.session))
  }
}
