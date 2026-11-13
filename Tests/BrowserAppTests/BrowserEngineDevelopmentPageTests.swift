// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserEngineDevelopmentPageTests {
  @Test func reloadAtSameURLIgnoresThePreviousFrameworkProbe() async throws {
    let store = BrowserStore()
    let url = try #require(URL(string: "http://localhost:5173/app"))
    store.perform(.open(url))
    let tabID = try #require(store.session.selectedSpace.selectedTab?.id)
    let runtime = DevelopmentProbeRuntime()
    runtime.tabWindows[tabID.uuidString] = "development-window"
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: runtime), windowID: "development-window", store: store)
    let target = SiteControlTarget(
      tabID: tabID, profileID: store.session.selectedSpace.profileID, url: url)
    engine.developerModels[tabID] = DeveloperPageModel(target: target, engine: engine)

    engine.updateDevelopmentPage(tabID: tabID, url: url, loading: true)
    engine.updateDevelopmentPage(tabID: tabID, url: url, loading: false)
    try await Task.sleep(for: .milliseconds(275))
    #expect(runtime.replies.count == 1)

    engine.updateDevelopmentPage(tabID: tabID, url: url, loading: true)
    engine.updateDevelopmentPage(tabID: tabID, url: url, loading: false)
    try await Task.sleep(for: .milliseconds(275))
    #expect(runtime.replies.count == 2)

    runtime.replies[0](
      ["result": ["value": "{\"resourcePaths\":[\"/@vite/client\"],\"documentMarkers\":[]}"]], nil)
    try await Task.sleep(for: .milliseconds(10))
    #expect(engine.developmentPages[tabID]?.detectedFramework == nil)

    runtime.replies[1](
      ["result": ["value": "{\"resourcePaths\":[\"/_next/static/app.js\"],\"documentMarkers\":[]}"]], nil)
    try await Task.sleep(for: .milliseconds(10))
    #expect(engine.developmentPages[tabID]?.detectedFramework == .nextJS)
    engine.developerModels.removeValue(forKey: tabID)?.close()
    engine.suspensionTask?.cancel()
  }

  @Test func completedLocalPageIsProbedOnceWithoutDiscardingEnrichment() throws {
    let store = BrowserStore()
    let url = try #require(URL(string: "http://localhost:5173/app"))
    store.perform(.open(url))
    let tabID = try #require(store.session.selectedSpace.selectedTab?.id)
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: ARCChromiumRuntime()), store: store)

    engine.updateDevelopmentPage(tabID: tabID, url: url, loading: true)
    #expect(engine.developmentPages[tabID]?.isDevelopmentPage == true)
    #expect(engine.developmentProbedURLs[tabID] == nil)

    engine.updateDevelopmentPage(tabID: tabID, url: url, loading: false)
    #expect(engine.developmentProbedURLs[tabID] == url)
    engine.developmentPages[tabID] = DevelopmentPage.detect(
      url: url, markers: DevelopmentPageMarkers(resourcePaths: ["/@vite/client"]))

    engine.updateDevelopmentPage(tabID: tabID, url: url, loading: false)
    #expect(engine.developmentPages[tabID]?.detectedFramework == .vite)
    #expect(engine.developmentProbedURLs[tabID] == url)
  }

  @Test func nonLocalPageDoesNotScheduleAFrameworkProbe() throws {
    let store = BrowserStore()
    let url = try #require(URL(string: "https://www.example.com"))
    store.perform(.open(url))
    let tabID = try #require(store.session.selectedSpace.selectedTab?.id)
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: ARCChromiumRuntime()), store: store)

    engine.updateDevelopmentPage(tabID: tabID, url: url, loading: false)

    #expect(engine.developmentPages[tabID]?.isDevelopmentPage == false)
    #expect(engine.developmentProbedURLs[tabID] == nil)
  }
}

@MainActor
private final class DevelopmentProbeRuntime: ARCChromiumRuntime {
  nonisolated(unsafe) var tabWindows: [String: String] = [:]
  nonisolated(unsafe) var replies: [@MainActor @Sendable ([String: Any]?, Error?) -> Void] = []

  override func windowID(forTabID tabID: String) -> String? { tabWindows[tabID] }

  override func endDeveloperSession(forTabID tabID: String, profileID: String, windowID: String) {}

  override func developerCall(
    _ method: String, params: [AnyHashable: Any], tabID: String, profileID: String,
    windowID: String, completion: @escaping @MainActor @Sendable ([String: Any]?, Error?) -> Void
  ) {
    replies.append(completion)
  }
}
