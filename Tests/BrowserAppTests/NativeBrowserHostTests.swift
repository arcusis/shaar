// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct NativeBrowserHostTests {
  @Test func closeTabTitleReflectsWhetherAWindowHasASelectedPage() {
    let store = BrowserStore()
    #expect(NativeBrowserHost.closeTabTitle(for: store) == "Close window")

    store.perform(.open(URL(string: "https://example.com")!))
    #expect(NativeBrowserHost.closeTabTitle(for: store) == "Close tab")
  }
}
