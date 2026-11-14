// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct NativeBrowserHostTests {
  @Test func nativeWindowFailureUsesLocalizedRecoveryNotice() {
    let error = NSError(
      domain: "NativeBrowserHostTests", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Raw English window error."])

    let message = NativeBrowserHost.localizedFailureNotice(for: error)

    #expect(
      message == ShellL10n.string("Could not complete the browser window action. Try again."))
    #expect(message != "Raw English window error.")
  }

  @Test func closeTabTitleReflectsWhetherAWindowHasASelectedPage() {
    let store = BrowserStore()
    #expect(NativeBrowserHost.closeTabTitle(for: store) == "Close window")

    store.perform(.open(URL(string: "https://example.com")!))
    #expect(NativeBrowserHost.closeTabTitle(for: store) == "Close tab")
  }
}
