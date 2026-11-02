// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

extension DeveloperPageModel {
  func setPerformanceEnabled(_ enabled: Bool) {
    performanceEnabled = enabled
    performanceSnapshot = nil
    schedule()
    if !enabled {
      Task {
        guard !performanceEnabled else { return }
        _ = try? await evaluate("globalThis.__shaarPerformanceV1?.dispose(); true")
      }
    }
  }

  func refreshPerformance() async throws {
    guard performanceEnabled else { return }
    try retainDeveloperSession()
    let generation = documentGeneration
    _ = try await call("Performance.enable")
    _ = try await evaluate(PagePerformanceScript.install)
    let metrics = try await call("Performance.getMetrics")
    guard
      let page = try await evaluate("globalThis.__shaarPerformanceV1.snapshot()") as? [String: Any],
      generation == documentGeneration, performanceEnabled, !Task.isCancelled
    else { return }
    performanceSnapshot = PagePerformanceSnapshot(
      page: page, engineMetrics: metrics["metrics"] as? [[String: Any]] ?? [])
  }

}
