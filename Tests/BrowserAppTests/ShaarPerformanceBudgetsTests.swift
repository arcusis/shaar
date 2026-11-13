// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite struct ShaarPerformanceBudgetsTests {
  @Test func evaluatesRouteMetricsAndLeavesMissingValuesUnknown() throws {
    let budget = ShaarRouteBudget(
      route: "/dashboard", lcpMilliseconds: 2_500, inpMilliseconds: 200,
      cls: 0.1, javascriptBytes: 500_000, requestCount: 30)
    let result = budget.evaluate(
      lcpMilliseconds: 1_800, inpMilliseconds: 84, cls: 0.02,
      javascriptBytes: nil, requestCount: 18)

    #expect(result.passed == 4)
    #expect(result.failed == 0)
    #expect(result.unavailable == 1)
    #expect(result.accessibilityDescription == "Route budget: 4 passed, 0 over, 1 unavailable")
    #expect(result.metrics.first { $0.name == "JavaScript" }?.status == .unavailable)
    let report = ShaarPerformanceBudgetReport(result: result)
    #expect(report.route == "/dashboard" && report.passed == 4 && report.unavailable == 1)
  }

  @Test func projectStoreRoundTripsAndRejectsInvalidBudgets() throws {
    let root = FileManager.default.temporaryDirectory
      .appending(path: "shaar-budget-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ShaarPerformanceBudgetStore()
    let configuration = ShaarPerformanceBudgetConfiguration(routes: [
      ShaarRouteBudget(
        route: "/", lcpMilliseconds: 2_500, inpMilliseconds: nil,
        cls: nil, javascriptBytes: nil, requestCount: nil)
    ])

    #expect(try store.load(from: root).routes.isEmpty)
    try store.save(configuration, to: root)
    #expect(try store.load(from: root) == configuration)
    #expect(store.fileURL(in: root).path.hasSuffix(".shaar/budgets.json"))

    let invalid = ShaarPerformanceBudgetConfiguration(routes: [
      ShaarRouteBudget(
        route: "../private", lcpMilliseconds: -1, inpMilliseconds: nil,
        cls: nil, javascriptBytes: nil, requestCount: nil)
    ])
    #expect(throws: (any Error).self) { try store.save(invalid, to: root) }
  }
}
