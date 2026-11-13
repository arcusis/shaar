// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct PageNavigationButtonsTests {
  @Test func splitPaneBackAndForwardFocusTheirOwnTabBeforeNavigation() throws {
    var session = BrowserSession.fresh()
    let firstValue = session.open(URL(string: "https://first.example")!)
    let secondValue = session.open(URL(string: "https://second.example")!)
    let first = try #require(firstValue)
    let second = try #require(secondValue)
    let spaceID = session.selectedSpaceID
    let split = session.splitTabs(first, second, in: spaceID)
    #expect(split)
    session.selectTab(first, in: spaceID)
    let store = BrowserStore(session: session)

    PageNavigationButtons(store: store, engine: nil, tabID: second).goBack()
    #expect(store.session.selectedSpace.selectedTabID == second)
    PageNavigationButtons(store: store, engine: nil, tabID: first).goForward()
    #expect(store.session.selectedSpace.selectedTabID == first)
  }
}
