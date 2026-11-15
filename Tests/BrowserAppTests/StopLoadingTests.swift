// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ArcusisBrowser

@Suite struct StopLoadingTests {
  @Test func toolbarSwitchesReloadToStopOnlyWhileLoading() {
    #expect(
      NavigationLoadingPresentation.forLoadingState(false)
        == NavigationLoadingPresentation(symbol: "arrow.clockwise", labelKey: "Reload (Command-R)"))
    #expect(
      NavigationLoadingPresentation.forLoadingState(true)
        == NavigationLoadingPresentation(symbol: "xmark", labelKey: "Stop Loading"))
  }
}
