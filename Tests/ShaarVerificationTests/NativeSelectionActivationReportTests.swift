// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@Suite struct NativeSelectionActivationReportTests {
  @Test func reportMustMatchTheCurrentActivationToken() {
    #expect(NativeSelectionActivationReportValidation.isForToken(["token": "current"], "current"))
    #expect(!NativeSelectionActivationReportValidation.isForToken(["token": "stale"], "current"))
    #expect(!NativeSelectionActivationReportValidation.isForToken(["tabID": 42], "current"))
  }
}
