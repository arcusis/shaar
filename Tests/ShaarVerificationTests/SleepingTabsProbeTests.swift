// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite @MainActor struct SleepingTabsProbeTests {
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
}
