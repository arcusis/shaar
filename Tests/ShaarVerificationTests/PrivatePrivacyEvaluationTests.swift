// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite struct PrivatePrivacyEvaluationTests {
  @Test func decodesOnlyJSONObjects() throws {
    #expect(try PrivatePrivacyEvaluation.decode(#"{"cookie":true}"#)["cookie"] as? Bool == true)
    for invalid in [nil, "", "not JSON", "null", "true", "[]"] as [String?] {
      #expect(throws: (any Error).self) {
        try PrivatePrivacyEvaluation.decode(invalid)
      }
    }
  }
}
