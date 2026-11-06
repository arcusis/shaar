// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser
@testable import ShaarVerification

@Suite @MainActor struct DevToolsPanelResultsTests {
  @Test func failedPanelIsPreservedInReportAndFailsTheGate() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let results = DevToolsPanelResults()
    for panel in DevToolsPanelResults.requiredPanels where panel != "masked-repro" {
      await results.check(panel) { "captured" }
    }
    await results.check("masked-repro") { throw PanelError() }

    #expect(throws: DevToolsPanelResults.Failure.self) {
      _ = try results.finish(root: root, phase: "initial", engine: "155.fixture", hidden: true)
    }
    let report = try readReport(root)
    let entries = try #require(report["results"] as? [String: [String: Any]])
    #expect(entries.count == DevToolsPanelResults.requiredPanels.count)
    #expect(entries["masked-repro"]?["passed"] as? Bool == false)
    #expect(entries["masked-repro"]?["detail"] as? String == "panel capture failed")
    #expect(report["hidden"] as? Bool == true)
  }

  @Test func missingPanelAndVisibleWindowCannotPass() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let results = DevToolsPanelResults()
    for panel in DevToolsPanelResults.requiredPanels where panel != "elements-live" {
      await results.check(panel) { "verified" }
    }
    #expect(throws: DevToolsPanelResults.Failure.self) {
      _ = try results.finish(root: root, phase: "restart", engine: "155.fixture", hidden: true)
    }
    await results.check("elements-live") { "verified" }
    #expect(throws: DevToolsPanelResults.Failure.self) {
      _ = try results.finish(root: root, phase: "restart", engine: "155.fixture", hidden: false)
    }

    let summaries = try results.finish(
      root: root, phase: "restart", engine: "155.fixture", hidden: true)
    #expect(summaries.count == DevToolsPanelResults.requiredPanels.count)
    #expect(summaries == summaries.sorted())
    #expect(try readReport(root, phase: "restart")["engine"] as? String == "155.fixture")
  }

  @Test func fixtureURLRetainsOriginAndRemovesStaleQuery() throws {
    let base = try #require(URL(string: "http://127.0.0.1:49187/old?token=stale"))
    let page = DevToolsPanelResults.fixtureURL("/inspector-tools", from: base)
    #expect(page.absoluteString == "http://127.0.0.1:49187/inspector-tools")
  }

  @Test func consoleAndNetworkReadinessRequiresBothFixtureEvents() {
    let unrelated = ShaarConsoleEvent(
      id: UUID(), level: .log, message: "other", source: nil)
    let console = ShaarConsoleEvent(
      id: UUID(), level: .error, message: "shaar19-live-console", source: nil)
    let network = ShaarNetworkEvent(
      id: UUID(), method: "GET", url: "http://127.0.0.1/profile-privacy-cache", status: 200)
    #expect(!DevToolsPanelResults.receivedConsoleAndNetwork([]))
    #expect(!DevToolsPanelResults.receivedConsoleAndNetwork([.console(unrelated)]))
    #expect(!DevToolsPanelResults.receivedConsoleAndNetwork([.console(console)]))
    #expect(!DevToolsPanelResults.receivedConsoleAndNetwork([.network(network)]))
    #expect(
      DevToolsPanelResults.receivedConsoleAndNetwork([
        .console(unrelated), .network(network), .console(console),
      ]))
  }

  @Test func readinessWaitRejectsAnAbsentSignal() async throws {
    let results = DevToolsPanelResults()
    try await results.wait("ready", attempts: 1) { true }
    do {
      try await results.wait("missing", attempts: 1) { false }
      Issue.record("Absent readiness signal unexpectedly passed")
    } catch let error as DevToolsPanelResults.Failure {
      #expect(error.errorDescription == "Timed out: missing")
    }
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "devtools-panel-results-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func readReport(_ root: URL, phase: String = "initial") throws -> [String: Any] {
    let path = root.appending(path: "\(phase)-devtools-panels.json")
    return try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
  }

  private struct PanelError: LocalizedError {
    let errorDescription: String? = "panel capture failed"
  }
}
