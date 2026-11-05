// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ShaarVerification

@MainActor
@Suite struct ShaarPreviewProbeTests {
  @Test func missingProbeInputsFailBeforeStartingTheEngine() {
    #expect(ShaarPreviewProbe.run(arguments: []) == 1)
    #expect(
      ShaarPreviewProbe.run(arguments: [
        "--probe-output", "/tmp/shaar-preview-report.json",
      ]) == 1)
    #expect(
      ShaarPreviewProbe.run(arguments: [
        "--probe-output", "/tmp/shaar-preview-report.json", "--probe-data-dir",
        "/tmp/shaar-preview-data",
      ]) == 1)
  }

  @Test func pendingQuitProbeRequiresLoopbackHTTP() throws {
    let target = try ShaarPreviewProbe.pendingQuitTarget(arguments: [
      "--probe-pending-quit-url", "http://127.0.0.1:8080/stall",
    ])
    #expect(target?.absoluteString == "http://127.0.0.1:8080/stall")
    #expect(
      (try? ShaarPreviewProbe.pendingQuitTarget(arguments: [
        "--probe-pending-quit-url", "https://example.com/stall",
      ])) == nil)
  }
}
