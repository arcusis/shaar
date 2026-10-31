// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing
@testable import ArcusisBrowser

struct SidebarVisibilityTests {
  @Test func pinnedAndHoverTransitions() {
    var visibility = SidebarVisibility.pinned
    visibility.pointerEnteredEdge()
    visibility.pointerLeftSidebar()
    #expect(visibility == .pinned)

    visibility.setPinned(false)
    #expect(visibility == .hidden)
    visibility.pointerEnteredEdge()
    #expect(visibility == .revealed)
    visibility.pointerLeftSidebar()
    #expect(visibility == .hidden)

    visibility.pointerEnteredEdge()
    visibility.setPinned(true)
    visibility.pointerLeftSidebar()
    #expect(visibility == .pinned)
    visibility.setPinned(false)
    #expect(visibility == .hidden)
  }
}
