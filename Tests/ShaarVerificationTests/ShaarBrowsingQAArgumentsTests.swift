// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ShaarVerification

@Suite @MainActor struct ShaarBrowsingQAArgumentsTests {
  @Test func missingCLIOperandsFailBeforeStartingTheEngine() {
    #expect(ShaarBrowsingQA.run(arguments: []) == 2)
    #expect(ShaarBrowsingQA.run(arguments: ["--browsing-qa"]) == 2)
    #expect(ShaarBrowsingQA.run(arguments: ["--browsing-qa", "report.json"]) == 2)
  }

  @Test func unsupportedScenarioReturnsStructuredErrorBeforeEngineStartup() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "browsing-qa-scenario-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appending(path: "result.json")

    let status = ShaarBrowsingQA.run(
      frameworkURL: root.appending(path: "missing-framework"), outputURL: output,
      pageURL: URL(string: "http://127.0.0.1:48123/"), scenario: "unknown")

    #expect(status == 2)
    let report = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
    #expect(report["passed"] as? Bool == false)
    #expect(report["error"] as? String == "Unknown scenario unknown.")
  }

  @Test func nonLoopbackBaseURLIsRejectedBeforeScenarioDispatch() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "browsing-qa-url-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appending(path: "result.json")

    let status = ShaarBrowsingQA.run(
      frameworkURL: root.appending(path: "missing-framework"), outputURL: output,
      pageURL: URL(string: "https://example.invalid/"), scenario: "overload-50")

    #expect(status == 2)
    let report = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
    #expect(report["error"] as? String == "Loopback http base URL is required.")
  }
}
