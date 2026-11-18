// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import ChromiumBridgeVerification
import Foundation
import Testing

@Suite @MainActor
struct ShaarActivationDispatchTests {
  @Test func hostSelectionCompletesWithoutWaitingForTheMainQueue() {
    var selected = false
    ARCDispatchShaarTabActivation { selected = true }
    #expect(selected)
  }

  @Test func rapidCrossSpaceFinalActivationIsNotDroppedAsAHostEvent() {
    // In [a, b, a], the final extension activation of a can be nested inside
    // the host's activation of b and inherit source=host from that operation.
    #expect(!ARCProbeShouldIgnoreHostTabActivationForTesting("host", "a", "b"))
    #expect(ARCProbeShouldIgnoreHostTabActivationForTesting("host", "b", "b"))
    #expect(!ARCProbeShouldIgnoreHostTabActivationForTesting("extension", "a", "b"))
  }

  @Test func nestedNativeNotificationsDeferSelectionUntilTabStripMutationReturns() async {
    var selections: [String] = []
    ARCPerformShaarEventCallback {
      ARCDispatchShaarTabActivation { selections.append("outer") }
      ARCPerformShaarEventCallback {
        ARCDispatchShaarTabActivation { selections.append("inner") }
      }
      ARCDispatchShaarTabActivation { selections.append("after-inner") }
      #expect(selections.isEmpty)
    }
    #expect(selections.isEmpty)
    // Host actions after the callback must no longer inherit its deferral.
    ARCDispatchShaarTabActivation { selections.append("host") }
    #expect(selections == ["host"])
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
    #expect(selections == ["host", "outer", "inner", "after-inner"])
  }
}
