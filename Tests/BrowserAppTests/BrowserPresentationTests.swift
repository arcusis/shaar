// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite
struct BrowserPresentationTests {
  @Test func sidebarVisibilityTransitionsPreservePinnedState() {
    var visibility = SidebarVisibility.hidden
    visibility.pointerLeftSidebar()
    #expect(visibility == .hidden)

    visibility.pointerEnteredEdge()
    #expect(visibility == .revealed)
    visibility.pointerEnteredEdge()
    #expect(visibility == .revealed)
    visibility.pointerLeftSidebar()
    #expect(visibility == .hidden)

    visibility.setPinned(true)
    visibility.pointerLeftSidebar()
    visibility.pointerEnteredEdge()
    #expect(visibility == .pinned)

    visibility.setPinned(false)
    #expect(visibility == .hidden)
  }

  @Test func librarySheetsHaveProfileScopedIdentityAndAreNotConsent() throws {
    let firstProfile = UUID()
    let secondProfile = UUID()
    let first = BrowserSheet.library(profileID: firstProfile, section: .bookmarks)
    let same = BrowserSheet.library(profileID: firstProfile, section: .bookmarks)
    let otherProfile = BrowserSheet.library(profileID: secondProfile, section: .bookmarks)
    let downloads = BrowserSheet.downloads(profileID: firstProfile)
    let spaceID = UUID()
    let session = try BrowserSession(
      profiles: [BrowserProfile(id: firstProfile, name: "Profile")],
      spaces: [
        BrowserSpace(
          id: spaceID, profileID: firstProfile, name: "Space", symbol: "square.stack",
          tint: .lavender)
      ], selectedSpaceID: spaceID)

    #expect(first.id == same.id)
    #expect(first.id != otherProfile.id)
    #expect(first.id != downloads.id)
    #expect(!first.isConsent && !downloads.isConsent)
    #expect(first.tabID == nil && !first.matches(session))
  }
}
