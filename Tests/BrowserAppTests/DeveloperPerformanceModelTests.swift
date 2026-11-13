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

  @Test func developerCallRejectsReplyAfterModelClose() async throws {
    var session = BrowserSession.fresh()
    let tabID = try #require(session.open(URL(string: "https://example.test")!))
    let page = try #require(session.page(forTabID: tabID)?.tab)
    let store = BrowserStore(session: session)
    let runtime = PendingDeveloperCallRuntime()
    let engine = try BrowserEngine(events: BrowserRuntimeEvents(runtime: runtime), store: store)
    defer { engine.suspensionTask?.cancel() }
    runtime.tabWindows[tabID.uuidString] = engine.windowID
    let target = SiteControlTarget(
      tabID: page.id, profileID: try #require(store.session.profileID(forTabID: page.id)),
      url: page.url)
    let model = DeveloperPageModel(target: target, engine: engine)
    let call = Task {
      do {
        _ = try await model.call("Runtime.evaluate")
        return false
      } catch is DeveloperModeFailure {
        return true
      } catch {
        return false
      }
    }
    for _ in 0..<100 where runtime.pending == nil { await Task.yield() }
    try #require(runtime.pending != nil)

    model.close()
    runtime.complete(with: ["result": [:]])

    #expect(await call.value)
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
