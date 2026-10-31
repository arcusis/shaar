// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ArcusisBrowser

@Test func spaceShortcutMapsOnlyFirstNineIndices() {
  #expect(
    (-1...10).map(SpaceShortcut.key(forIndex:)) == [
      nil, "1", "2", "3", "4", "5", "6", "7", "8", "9", nil, nil,
    ])
}
