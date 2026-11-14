// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite @MainActor struct SiteControlsProbeReportTests {
  @Test func reportPreservesFailureAndCompletedChecks() throws {
    struct Failure: LocalizedError {
      var errorDescription: String? { "Fixture action did not settle" }
    }

    let failed = try JSONSerialization.jsonObject(
      with: SiteControlsProbe.reportData(phase: "initial", checks: ["permissions"], error: Failure())
    ) as? [String: Any]
    #expect(failed?["passed"] as? Bool == false)
    #expect(failed?["phase"] as? String == "initial")
    #expect(failed?["checks"] as? [String] == ["permissions"])
    #expect(failed?["error"] as? String == "Fixture action did not settle")

    let passed = try JSONSerialization.jsonObject(
      with: SiteControlsProbe.reportData(
        phase: "restart", checks: ["permissions", "reload"], error: nil)
    ) as? [String: Any]
    #expect(passed?["passed"] as? Bool == true)
    #expect(passed?["phase"] as? String == "restart")
    #expect(passed?["checks"] as? [String] == ["permissions", "reload"])
    #expect(passed?["error"] is NSNull)
    #expect((passed?["scope"] as? String)?.contains("authored loopback page") == true)
  }
}
