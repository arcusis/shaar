// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct BitwardenProbeEvidenceTests {
  @Test func addToChromeMustBeExplicitlyEnabled() {
    #expect(BitwardenProbeEvidence.hasEnabledAddToChromeButton([
      ["text": "Add to Chrome", "disabled": false]
    ]))
    #expect(!BitwardenProbeEvidence.hasEnabledAddToChromeButton([
      ["text": "Add to Chrome", "disabled": true]
    ]))
    for malformed in [
      ["text": "Add to Chrome"],
      ["text": "Add to Chrome", "disabled": "false"],
      ["text": "Different button", "disabled": false],
    ] as [[String: Any]] {
      #expect(!BitwardenProbeEvidence.hasEnabledAddToChromeButton([malformed]))
    }
  }
}
