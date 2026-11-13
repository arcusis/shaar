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
