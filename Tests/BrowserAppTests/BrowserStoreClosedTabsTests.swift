// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserStoreClosedTabsTests {
  @Test func clearingRecentlyClosedTabsKeepsThePanelOpenAndDisablesReopen() throws {
    let store = BrowserStore()
    store.perform(.open(try #require(URL(string: "https://first.example/page"))))
    let first = try #require(store.session.selectedSpace.selectedTabID)
    store.closeTab(first)
    store.nativeTabClosed(first)
    store.perform(.open(try #require(URL(string: "https://second.example/page"))))
    let second = try #require(store.session.selectedSpace.selectedTabID)
    store.closeTab(second)
    store.nativeTabClosed(second)
    #expect(store.canReopenClosedTab)

    let spaceID = store.session.selectedSpaceID
    store.showRecentlyClosed()
    #expect(store.clearClosedTabs(in: spaceID))

    #expect(store.session.recentlyClosedTabs(in: spaceID).isEmpty)
    #expect(!store.canReopenClosedTab)
    #expect(store.sheet?.id == BrowserSheet.recentlyClosed(spaceID: spaceID).id)
    #expect(!store.reopenLastClosedTab())
  }
}
