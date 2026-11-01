// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite @MainActor struct InspectorEvidenceTests {
  @Test func reportRetainsPartialChecksAndFailureWithoutClaimingSuccess() throws {
    struct Failure: LocalizedError { var errorDescription: String? { "Renderer unavailable" } }
    let failed =
      try JSONSerialization.jsonObject(
        with: InspectorProbe.reportData(checks: ["hover"], error: Failure())) as? [String: Any]
    #expect(failed?["passed"] as? Bool == false)
    #expect(failed?["checks"] as? [String] == ["hover"])
    #expect(failed?["error"] as? String == "Renderer unavailable")
    let passed =
      try JSONSerialization.jsonObject(
        with: InspectorProbe.reportData(checks: ["hover", "lock"], error: nil)) as? [String: Any]
    #expect(passed?["passed"] as? Bool == true)
    #expect(passed?["error"] is NSNull)
    #expect((passed?["scope"] as? String)?.contains("Offscreen") == true)
  }
}
