// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct NativeWindowProbeEvidenceTests {
  @Test func webStoreFitRequiresIntegerMeasurementsFromTheRightFixture() {
    let valid = NativeWindowProbeEvidence.webStoreFit(
      ["fixture": "web-store-fit", "width": 1024, "overflow": 0])
    #expect(valid?.width == 1024 && valid?.overflow == 0)
    #expect(
      NativeWindowProbeEvidence.webStoreFit(
        ["fixture": "web-store-fit", "width": 1024.5, "overflow": 0]) == nil)
    #expect(
      NativeWindowProbeEvidence.webStoreFit(
        ["fixture": "web-store-fit", "width": true, "overflow": 0]) == nil)
    #expect(
      NativeWindowProbeEvidence.webStoreFit(
        ["fixture": "web-store-fit", "width": "1024", "overflow": 0]) == nil)
    #expect(
      NativeWindowProbeEvidence.webStoreFit(
        ["fixture": "other", "width": 1024, "overflow": 0]) == nil)
    #expect(
      NativeWindowProbeEvidence.webStoreFit(
        ["fixture": "web-store-fit", "width": 1024]) == nil)
  }
}
