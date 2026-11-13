// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import BrowserCore
import ChromiumBridge
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct DeveloperPerformanceModelTests {
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

  @Test func closingCancelsThePendingDeveloperDrainCall() async throws {
    let store = BrowserStore(session: .fresh())
    store.perform(.open(try #require(URL(string: "https://developer.example"))))
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let runtime = PendingDeveloperCallRuntime()
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: runtime), windowID: "developer-window", store: store)
    runtime.tabWindows[tab.id.uuidString] = "developer-window"
    let target = SiteControlTarget(
      tabID: tab.id, profileID: try #require(store.session.profileID(forTabID: tab.id)),
      url: tab.url)
    let model = DeveloperPageModel(target: target, engine: engine)
    var simulation = DeveloperSimulation()
    simulation.darkMode = true

    model.set(simulation)
    for _ in 0..<100 where runtime.pending == nil { await Task.yield() }
    try #require(runtime.pending != nil)

    model.close()
    for _ in 0..<100 where model.applying { await Task.yield() }
    #expect(!model.applying)
    runtime.complete(with: ["result": ["value": "fixture-agent"]])
    engine.suspensionTask?.cancel()
  }
}

@MainActor
private final class PendingDeveloperCallRuntime: ARCChromiumRuntime {
  nonisolated(unsafe) var tabWindows: [String: String] = [:]
  nonisolated(unsafe) var pending: (@MainActor @Sendable ([String: Any]?, Error?) -> Void)?

  override func windowID(forTabID tabID: String) -> String? { tabWindows[tabID] }

  override func beginDeveloperSession(
    forTabID tabID: String, profileID: String, windowID: String
  ) -> Bool { true }

  override func endDeveloperSession(forTabID tabID: String, profileID: String, windowID: String) {}

  override func developerCall(
    _ method: String, params: [AnyHashable: Any], tabID: String, profileID: String,
    windowID: String,
    completion: @escaping @MainActor @Sendable ([String: Any]?, (any Error)?) -> Void
  ) {
    pending = completion
  }

  func complete(with result: [String: Any]) {
    pending?(result, nil)
    pending = nil
  }
}
