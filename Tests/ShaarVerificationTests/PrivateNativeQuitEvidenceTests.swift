// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridgeVerification
import Testing

@testable import ShaarVerification

@Suite @MainActor struct PrivateNativeQuitEvidenceTests {
  @Test func cancellationEventSurvivesTransientRuntimeQuitFlag() {
    #expect(
      PrivateProductHostProbe.observedNativeQuitCancellation(
        requestEventObserved: true, cancellationEventObserved: true))
    #expect(
      !PrivateProductHostProbe.observedNativeQuitCancellation(
        requestEventObserved: true, cancellationEventObserved: false))
    #expect(
      !PrivateProductHostProbe.observedNativeQuitCancellation(
        requestEventObserved: false, cancellationEventObserved: true))
  }

  @Test func canceledQuitHoldCleanupRequiresLiveOwnerAndCompletedQuit() {
    #expect(ARCProbeShouldReleaseCanceledQuitHold(false, true))
    #expect(!ARCProbeShouldReleaseCanceledQuitHold(true, true))
    #expect(!ARCProbeShouldReleaseCanceledQuitHold(false, false))
  }
}
