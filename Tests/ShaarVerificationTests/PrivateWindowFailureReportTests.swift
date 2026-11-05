// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite("Private window failure evidence")
struct PrivateWindowFailureReportTests {
  @Test @MainActor func writesPreflightErrorBeforePrivateProbeStarts() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let runID = UUID().uuidString
    let message = "store selects live normal Alpha WebContents before private fixture"

    try PrivateWindowProbe.writeEarlyFailure(
      root: root, phase: "initial", runID: runID, error: message)

    let path = root.appending(path: "initial-private-window.json")
    let data = try Data(contentsOf: path)
    let report = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(report["mode"] as? String == PrivateWindowProbe.mode)
    #expect(report["runID"] as? String == runID)
    #expect(report["passed"] as? Bool == false)
    #expect(report["lastStage"] as? String == "engine-preflight")
    #expect(report["error"] as? String == message)
  }
}
