// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserStoreSpaceProfileTests {
  @Test func spaceMenuOnlyAllowsDeletingWhenAnotherSpaceRemains() {
    #expect(!SpaceMenuContent.canDeleteSpace(spaceCount: 0))
    #expect(!SpaceMenuContent.canDeleteSpace(spaceCount: 1))
    #expect(SpaceMenuContent.canDeleteSpace(spaceCount: 2))
  }
}
