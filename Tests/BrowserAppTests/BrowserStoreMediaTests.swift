// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserStoreMediaTests {
  @Test func visiblePagesIncludeEveryPaneInTheSelectedSplit() throws {
    var session = BrowserSession.fresh()
    let firstResult = session.open(URL(string: "https://first-pane.example")!)
    let first = try #require(firstResult)
    let secondResult = session.open(URL(string: "https://second-pane.example")!)
    let second = try #require(secondResult)
    let store = BrowserStore(session: session)

    store.splitTabs(first, second)

    #expect(Set(try #require(store.selectedSplit?.tabIDs)) == Set([first, second]))
    #expect(store.visiblePageIDs == Set([first, second]))
  }
}
