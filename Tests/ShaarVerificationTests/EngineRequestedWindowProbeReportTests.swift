// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite @MainActor struct EngineRequestedWindowProbeReportTests {
  @Test func reportIncludesPhaseAndPreservesFailureEvidence() throws {
    struct Failure: LocalizedError {
      var errorDescription: String? { "Window close was not observed" }
    }

    let observations: [[String: Any]] = [["requestedType": "popup"]]
    let rollback = ["ownerPreserved": true, "modelOrderPreserved": false]
    let failed = try JSONSerialization.jsonObject(
      with: EngineRequestedWindowProbe.reportData(
        phase: "restart", checks: ["created"], observations: observations,
        rollback: rollback, error: Failure())) as? [String: Any]
    #expect(failed?["passed"] as? Bool == false)
    #expect(failed?["phase"] as? String == "restart")
    #expect(failed?["checks"] as? [String] == ["created"])
    #expect(failed?["error"] as? String == "Window close was not observed")
    #expect(failed?["rollback"] as? [String: Bool] == rollback)
    #expect((failed?["observations"] as? [[String: String]])?.first == ["requestedType": "popup"])

    let passed = try JSONSerialization.jsonObject(
      with: EngineRequestedWindowProbe.reportData(
        phase: "initial", checks: ["created", "closed"], observations: [], rollback: [:],
        error: nil)) as? [String: Any]
    #expect(passed?["passed"] as? Bool == true)
    #expect(passed?["phase"] as? String == "initial")
    #expect(passed?["error"] is NSNull)
    #expect((passed?["scope"] as? String)?.contains("hidden managed normal-profile windows") == true)
  }
}
