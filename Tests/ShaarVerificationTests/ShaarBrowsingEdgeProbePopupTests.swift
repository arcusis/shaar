// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct ShaarBrowsingEdgeProbePopupTests {
  @Test func popupVerdictRequiresExactlyOneDestinationAndRetainedSource() {
    #expect(
      ShaarBrowsingEdgeProbe.popupAdoptionPassed(
        createdTabCount: 1, destinationReady: true, sourceRetained: true))
    #expect(
      !ShaarBrowsingEdgeProbe.popupAdoptionPassed(
        createdTabCount: 2, destinationReady: true, sourceRetained: true))
    #expect(
      !ShaarBrowsingEdgeProbe.popupAdoptionPassed(
        createdTabCount: 1, destinationReady: false, sourceRetained: true))
    #expect(
      !ShaarBrowsingEdgeProbe.popupAdoptionPassed(
        createdTabCount: 1, destinationReady: true, sourceRetained: false))
  }
}
