// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite @MainActor struct NativeWindowProbeReportTests {
  @Test func reportPreservesWindowObservationsAndFailureStatus() throws {
    struct Failure: LocalizedError {
      var errorDescription: String? { "Secondary window did not close" }
    }
    let observations: [String: Any] = ["windowIDs": ["primary", "secondary"]]
    let closedWindows = ["secondary": true]

    let failed = try JSONSerialization.jsonObject(
      with: NativeWindowProbe.reportData(
        phase: "initial", checks: ["created"], observations: observations,
        closedWindows: closedWindows, error: Failure())) as? [String: Any]
    #expect(failed?["passed"] as? Bool == false)
    #expect(failed?["phase"] as? String == "initial")
    #expect(failed?["checks"] as? [String] == ["created"])
    #expect(failed?["closedWindows"] as? [String: Bool] == closedWindows)
    #expect(failed?["error"] as? String == "Secondary window did not close")
    #expect(((failed?["observations"] as? [String: Any])?["windowIDs"] as? [String]) == [
      "primary", "secondary",
    ])

    let passed = try JSONSerialization.jsonObject(
      with: NativeWindowProbe.reportData(
        phase: "restart", checks: ["created", "closed"], observations: [:],
        closedWindows: [:], error: nil)) as? [String: Any]
    #expect(passed?["passed"] as? Bool == true)
    #expect(passed?["error"] is NSNull)
    #expect((passed?["scope"] as? String)?.contains("no visible windows") == true)
  }
}
