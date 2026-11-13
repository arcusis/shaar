// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct DeveloperPerformanceModelTests {
  @Test func runtimeSimulationFailuresUseLocalizedRecoveryCopy() {
    let error = NSError(domain: "DevTools", code: 1, userInfo: [NSLocalizedDescriptionKey: "The engine refused."])
    #expect(
      DeveloperPageModel.failureMessage(for: error)
        == InspectorToolsL10n.string("Could not apply developer settings. Try again."))
    let known = DeveloperModeFailure("The page changed. Try again.")
    #expect(DeveloperPageModel.failureMessage(for: known) == known.localizedDescription)
  }

  @Test func disablingPerformanceClearsThePreviousSnapshot() async throws {
    let model = DeveloperPageModel(
      target: SiteControlTarget(
        tabID: UUID(), profileID: UUID(), url: try #require(URL(string: "https://example.test"))),
      engine: nil)
    model.performanceEnabled = true
    model.performanceSnapshot = PagePerformanceSnapshot(page: ["requests": 5], engineMetrics: [])

    model.setPerformanceEnabled(false)
    await Task.yield()

    #expect(!model.performanceEnabled)
    #expect(model.performanceSnapshot == nil)
  }

  @Test func refreshingWhileDisabledDoesNotReplaceTheSnapshot() async throws {
    let model = DeveloperPageModel(
      target: SiteControlTarget(
        tabID: UUID(), profileID: UUID(), url: try #require(URL(string: "https://example.test"))),
      engine: nil)
    let previous = PagePerformanceSnapshot(page: ["requests": 5], engineMetrics: [])
    model.performanceSnapshot = previous

    try await model.refreshPerformance()

    #expect(!model.performanceEnabled)
    #expect(model.performanceSnapshot == previous)
  }

  @Test func enabledRefreshRequiresAnOwnedDeveloperSession() async throws {
    let model = DeveloperPageModel(
      target: SiteControlTarget(
        tabID: UUID(), profileID: UUID(), url: try #require(URL(string: "https://example.test"))),
      engine: nil)
    model.performanceEnabled = true

    await #expect(throws: DeveloperModeFailure.self) {
      try await model.refreshPerformance()
    }
    #expect(model.performanceSnapshot == nil)
  }
}
