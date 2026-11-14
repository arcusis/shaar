// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite
struct SidebarPinnedItemsTests {
  @Test func snapshotBuildsPinnedItemsOnceAndReusesTheResult() {
    let tab = BrowserTab(
      url: URL(string: "https://example.com/pinned")!, title: "Pinned", isPinned: true)
    let space = BrowserSpace(
      profileID: UUID(), name: "Main", symbol: "house", tint: .ocean, tabs: [tab])
    var buildCount = 0

    let snapshot = SidebarPinnedItems {
      buildCount += 1
      return space.sidebarItemSections().pinned
    }

    #expect(buildCount == 1)
    #expect(snapshot.items == [.tab(tab, depth: 0)])
    #expect(!snapshot.isEmpty)
    #expect(snapshot.items.first == .tab(tab, depth: 0))
    #expect(buildCount == 1)
    #expect(SidebarPinnedItems { space.sidebarItemSections().pinned }.items == [.tab(tab, depth: 0)])
  }
}
