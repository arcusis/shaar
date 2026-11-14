// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct ProbeTimeoutTests {
  @Test func timeoutScaleDefaultsAndClampsInvalidOrSubunitValues() {
    for value: String? in [nil, "", "invalid", "0", "0.75", "inf", "-inf", "nan"] {
      #expect(ProbeTimeout.scale(from: value) == 1)
    }
  }

  @Test func timeoutScalePreservesValidValuesAtOrAboveOne() {
    #expect(ProbeTimeout.scale(from: "1") == 1)
    #expect(ProbeTimeout.scale(from: "1.25") == 1.25)
    #expect(ProbeTimeout.scale(from: "2") == 2)
  }

  @Test func timeoutScaleRejectsNonfiniteValues() {
    #expect(ProbeTimeout.scale(from: "infinity") == 1)
    #expect(ProbeTimeout.scale(from: "-infinity") == 1)
    #expect(ProbeTimeout.scale(from: "nan") == 1)
  }
}
