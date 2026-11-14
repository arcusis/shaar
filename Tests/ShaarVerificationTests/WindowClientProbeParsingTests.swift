// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite @MainActor struct WindowClientProbeParsingTests {
  @Test func parsesObjectAndScalarEvaluationResults() throws {
    let object = try #require(
      WindowClientProbe.parseEvaluationJSON("{\"fixture\":\"v1\"}") as? [String: String])
    #expect(object["fixture"] == "v1")
    #expect(try WindowClientProbe.parseEvaluationJSON("false") as? Bool == false)
    #expect(try WindowClientProbe.parseEvaluationJSON("null") is NSNull)
    #expect(try WindowClientProbe.parseEvaluationJSON("17") as? Int == 17)
    #expect(try WindowClientProbe.parseEvaluationJSON("\"ready\"") as? String == "ready")
  }

  @Test func rejectsMissingAndMalformedEvaluationResults() {
    #expect(throws: WindowClientFailure.self) {
      try WindowClientProbe.parseEvaluationJSON(nil)
    }
    var malformedError: Error?
    do {
      _ = try WindowClientProbe.parseEvaluationJSON("{not json}")
    } catch { malformedError = error }
    #expect(malformedError != nil)
  }
}
