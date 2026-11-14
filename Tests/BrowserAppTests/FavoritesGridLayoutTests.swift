// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import SwiftUI
import Testing

@testable import ArcusisBrowser

struct FavoritesGridLayoutTests {
  @Test func legacyFavoritesBeyondTheLimitRemainReachable() {
    #expect(FavoritesGridLayout.rows(for: 13) == nil)

    let frames = FavoritesGridLayout.frames(count: 13, width: 212)

    #expect(frames.count == 13)
    #expect(frames.allSatisfy { $0.minX >= 0 && $0.maxX <= 212 })
    #expect(frames.map(\.minY) == [0, 0, 0, 0, 52, 52, 52, 104, 104, 104, 156, 156, 156])
    #expect(frames.last?.maxY == 200)
  }
}
