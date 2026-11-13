// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ArcusisBrowser

struct InspectorDetailsL10nTests {
  @Test func ltrTextIsIsolatedFromSurroundingRightToLeftCopy() {
    let value = "https://example.test/path?q=שלום"
    #expect(InspectorDetailsL10n.ltr(value) == "\u{2066}\(value)\u{2069}")
  }
}
