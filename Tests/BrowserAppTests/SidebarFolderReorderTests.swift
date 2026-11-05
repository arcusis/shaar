// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct SidebarFolderReorderTests {
  @Test func rootFolderMoveChoicesStayWithinTheirSection() throws {
    let store = BrowserStore()
    let spaceID = store.session.selectedSpaceID
    let pinnedID = try #require(store.createFolder(name: "Pinned", in: spaceID, section: .pinned))
    let todayID = try #require(store.createFolder(name: "Today", in: spaceID, section: .today))
    let secondPinnedID = try #require(
      store.createFolder(name: "Pinned Two", in: spaceID, section: .pinned))
    let space = store.session.selectedSpace
    let pinned = try #require(space.folders.first { $0.id == pinnedID })
    let today = try #require(space.folders.first { $0.id == todayID })

    #expect(
      SidebarFolderReorder.siblings(of: pinned, in: space).map(\.id) == [
        pinnedID, secondPinnedID,
      ])
    #expect(SidebarFolderReorder.siblings(of: today, in: space).map(\.id) == [todayID])
  }
}
