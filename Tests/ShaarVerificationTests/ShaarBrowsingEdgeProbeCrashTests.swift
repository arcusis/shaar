// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct ShaarBrowsingEdgeProbeCrashTests {
  @Test func crashRecoveryRequiresTheRestoredPageAndAResponsiveRenderer() {
    #expect(
      ShaarBrowsingEdgeProbe.crashRecoveryPassed(
        started: true, restored: true, marker: "crash-target", responsive: true,
        windowsHidden: true))
    #expect(
      !ShaarBrowsingEdgeProbe.crashRecoveryPassed(
        started: true, restored: true, marker: nil, responsive: true,
        windowsHidden: true))
    #expect(
      !ShaarBrowsingEdgeProbe.crashRecoveryPassed(
        started: true, restored: true, marker: "stale page", responsive: true,
        windowsHidden: true))
    #expect(
      !ShaarBrowsingEdgeProbe.crashRecoveryPassed(
        started: true, restored: true, marker: "crash-target", responsive: false,
        windowsHidden: true))
  }
}
