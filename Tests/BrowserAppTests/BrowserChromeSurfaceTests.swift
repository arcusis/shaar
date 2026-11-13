// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite
struct BrowserChromeSurfaceTests {
  @Test func controlCountsAccumulateAcrossPreferenceChildren() {
    var counts = ["browser.back": 1, "browser.sidebar": 1]

    BrowserChromeControlCountPreferenceKey.reduce(value: &counts) {
      ["browser.back": 2, "browser.forward": 1]
    }

    #expect(counts == ["browser.back": 3, "browser.sidebar": 1, "browser.forward": 1])
  }
}
