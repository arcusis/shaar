// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct BrowserEnginePendingReloadTests {
  @Test func restartingPendingNavigationStopsBeforeNavigatingToDestination() {
    var operations: [String] = []

    let accepted = BrowserEngine.restartPendingNavigation(
      stop: {
        operations.append("stop")
        return true
      },
      navigate: {
        operations.append("navigate")
        return true
      })

    #expect(accepted)
    #expect(operations == ["stop", "navigate"])
  }

  @Test func rejectedStopDoesNotSubmitReplacementNavigation() {
    var navigateCalled = false

    let accepted = BrowserEngine.restartPendingNavigation(
      stop: { false },
      navigate: {
        navigateCalled = true
        return true
      })

    #expect(!accepted)
    #expect(!navigateCalled)
  }
}
