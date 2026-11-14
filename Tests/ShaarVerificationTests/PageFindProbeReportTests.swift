// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite @MainActor struct PageFindProbeReportTests {
  @Test func reportPreservesPhaseChecksAndFailureStatus() throws {
    struct Failure: LocalizedError {
      var errorDescription: String? { "Find service unavailable" }
    }

    let failed = try JSONSerialization.jsonObject(
      with: PageFindProbe.reportData(phase: "restart", checks: ["search"], error: Failure())
    ) as? [String: Any]
    #expect(failed?["passed"] as? Bool == false)
    #expect(failed?["phase"] as? String == "restart")
    #expect(failed?["checks"] as? [String] == ["search"])
    #expect(failed?["error"] as? String == "Find service unavailable")

    let passed = try JSONSerialization.jsonObject(
      with: PageFindProbe.reportData(phase: "initial", checks: ["search", "capture"], error: nil)
    ) as? [String: Any]
    #expect(passed?["passed"] as? Bool == true)
    #expect(passed?["phase"] as? String == "initial")
    #expect(passed?["checks"] as? [String] == ["search", "capture"])
    #expect(passed?["error"] is NSNull)
    #expect((passed?["scope"] as? String)?.contains("keyboard focus") == true)
  }
}
