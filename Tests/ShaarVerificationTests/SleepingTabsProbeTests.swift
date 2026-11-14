// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite @MainActor struct SleepingTabsProbeTests {
  @Test func failureClassifierReportsEachSleepingTabInvariant() {
    #expect(failure(capable: false) == "The engine cannot discard this tab")
    #expect(failure(sleeping: false) == "The background tab stayed awake")
    #expect(failure(awake: false) == "The background tab did not wake")
    #expect(failure(stillListed: false) == "The background tab left the window")
    #expect(failure(stillLive: false) == "The background tab is no longer live")
    #expect(failure(hidden: false) == "A window became visible")
    #expect(failure(wasOpen: false) == "The background tab was not open before sleep")
    #expect(failure(rendererFailures: 1) == "The renderer failed")
    #expect(failure() == nil)
  }

  @Test func aMissingEngineFailsTheVerdict() throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "sleeping-tabs-probe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appending(path: "report.json")
    let code = SleepingTabsProbe.run(
      frameworkURL: URL(fileURLWithPath: "/tmp/shaar-missing-chromium.framework"),
      outputURL: output)
    #expect(code == 1)
    let object = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
    #expect(object["passed"] as? Bool == false)
  }

  private func failure(
    capable: Bool = true, sleeping: Bool = true, awake: Bool = true,
    stillListed: Bool = true, stillLive: Bool = true, hidden: Bool = true,
    wasOpen: Bool = true, rendererFailures: Int = 0
  ) -> String? {
    SleepingTabsProbe.probeFailure(
      capable: capable, sleeping: sleeping, awake: awake, stillListed: stillListed,
      stillLive: stillLive, hidden: hidden, wasOpen: wasOpen, rendererFailures: rendererFailures)
  }
}
