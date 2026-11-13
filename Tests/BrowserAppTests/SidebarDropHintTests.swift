// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ArcusisBrowser

struct SidebarDropHintTests {
  @Test @MainActor func targetAnimationRespectsReduceMotion() {
    #expect(SidebarDropHint.targetAnimation(reduceMotion: true) == nil)
    #expect(SidebarDropHint.targetAnimation(reduceMotion: false) != nil)
  }
}
