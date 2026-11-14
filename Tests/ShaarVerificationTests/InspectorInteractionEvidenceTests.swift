// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct InspectorInteractionEvidenceTests {
  @Test func nativeAndDOMInputMustMatchTheirTrustContractWithoutActivation() {
    #expect(InspectorInteractionEvidence.acceptsInput(
      trusted: true, activated: 0, usesDOMEvents: false))
    #expect(InspectorInteractionEvidence.acceptsInput(
      trusted: false, activated: 0, usesDOMEvents: true))
    #expect(!InspectorInteractionEvidence.acceptsInput(
      trusted: false, activated: 0, usesDOMEvents: false))
    #expect(!InspectorInteractionEvidence.acceptsInput(
      trusted: true, activated: 0, usesDOMEvents: true))
    #expect(!InspectorInteractionEvidence.acceptsInput(
      trusted: true, activated: 1, usesDOMEvents: false))
    #expect(!InspectorInteractionEvidence.acceptsInput(
      trusted: nil, activated: 0, usesDOMEvents: false))
  }
}
