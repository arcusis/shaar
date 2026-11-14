// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite @MainActor struct BitwardenProbeReportTests {
  @Test func failureReportPreservesPhaseChecksAndControlScope() throws {
    struct Failure: LocalizedError {
      var errorDescription: String? { "Store consent was not presented" }
    }

    let data = try BitwardenProbe.failureReportData(
      phase: "restart", checks: ["store-page", "native-consent"], error: Failure(),
      controlOnly: true)
    let report = try JSONSerialization.jsonObject(with: data) as? [String: Any]

    #expect(report?["passed"] as? Bool == false)
    #expect(report?["error"] as? String == "Store consent was not presented")
    #expect(report?["checks"] as? [String] == ["store-page", "native-consent"])
    #expect(report?["phase"] as? String == "restart")
    #expect(report?["controlOnly"] as? Bool == true)
    #expect(report?["firstClickAcceptancePassed"] as? Bool == false)
    #expect(report?["scope"] as? String == "Disposable real-store extension test.")
  }
}
