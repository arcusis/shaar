// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite
struct ProfileColorTests {
  @Test func profileSymbolUsesDefaultOnlyWhenNoSymbolWasSaved() {
    let profile = BrowserProfile(id: UUID(), name: "Personal")

    #expect(profile.displaySymbol == "person.fill")
    #expect(profile.displaySymbol == BrowserProfile.defaultSymbol)

    var customized = profile
    customized.symbol = "house.fill"
    #expect(customized.displaySymbol == "house.fill")
  }
}
