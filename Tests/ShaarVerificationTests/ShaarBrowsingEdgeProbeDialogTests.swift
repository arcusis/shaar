// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct ShaarBrowsingEdgeProbeDialogTests {
  @Test func beforeUnloadRequiresNavigationAfterTheDialog() {
    #expect(
      ShaarBrowsingEdgeProbe.beforeUnloadProbePassed(
        exercised: true, dialogCount: 1, navigated: true, windowsHidden: true))
    #expect(
      !ShaarBrowsingEdgeProbe.beforeUnloadProbePassed(
        exercised: true, dialogCount: 1, navigated: false, windowsHidden: true))
    #expect(
      !ShaarBrowsingEdgeProbe.beforeUnloadProbePassed(
        exercised: true, dialogCount: 0, navigated: true, windowsHidden: true))
    #expect(
      !ShaarBrowsingEdgeProbe.beforeUnloadProbePassed(
        exercised: true, dialogCount: 1, navigated: true, windowsHidden: false))
  }
}
