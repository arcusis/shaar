// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct QuitExitProbeEvidenceTests {
  @Test func backgroundModeMustBeExplicitlyDisabledByJSONBoolean() {
    #expect(QuitExitProbeEvidence.backgroundModeIsOff(["background_mode": ["enabled": false]]))
    for state in [
      [:],
      ["background_mode": [:]],
      ["background_mode": ["enabled": true]],
      ["background_mode": ["enabled": 0]],
      ["background_mode": ["enabled": "false"]],
    ] as [[String: Any]] {
      #expect(!QuitExitProbeEvidence.backgroundModeIsOff(state))
    }
  }
}
