// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct InspectorIdlePollEvidenceTests {
  @Test func idlePollCountMustStayWithinTheMeasuredBackoffBudget() {
    #expect(InspectorIdlePollEvidence.stayedBackedOff(2))
    #expect(InspectorIdlePollEvidence.stayedBackedOff(12))
    #expect(!InspectorIdlePollEvidence.stayedBackedOff(1))
    #expect(!InspectorIdlePollEvidence.stayedBackedOff(13))
    #expect(!InspectorIdlePollEvidence.stayedBackedOff(0))
  }
}
