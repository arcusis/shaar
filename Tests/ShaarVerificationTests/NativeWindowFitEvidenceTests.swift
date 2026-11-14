// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct NativeWindowFitEvidenceTests {
  @Test func fitMeasurementRequiresAuthoredFixtureAndExactIntegers() {
    #expect(
      NativeWindowFitEvidence.parse(
        ["fixture": "web-store-fit", "width": 1400, "overflow": 0])
        == NativeWindowFitEvidence(width: 1400, overflow: 0))
    for invalid: [String: Any] in [
      ["fixture": "other", "width": 1400, "overflow": 0],
      ["fixture": "web-store-fit", "width": true, "overflow": 0],
      ["fixture": "web-store-fit", "width": 1400, "overflow": false],
      ["fixture": "web-store-fit", "width": 1400.5, "overflow": 0],
      ["fixture": "web-store-fit", "width": 1400, "overflow": 0.5],
      ["fixture": "web-store-fit", "width": "1400", "overflow": 0],
      ["fixture": "web-store-fit", "width": 1400],
    ] {
      #expect(NativeWindowFitEvidence.parse(invalid) == nil)
    }
  }
}
