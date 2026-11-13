// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserEngineDevToolsTests {
  @Test func extensionInstallRefreshUsesBackoffInsteadOfFixedPolling() {
    #expect(BrowserEngine.extensionInstallRefreshDelaysMilliseconds == [250, 750, 1_500, 3_000, 4_500])
  }

  @Test func developerToolsOpenOnlyForTheCurrentLiveOwnedPage() throws {
    let store = BrowserStore()
    store.perform(.open(try #require(URL(string: "https://inspect.example/page"))))
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let runtime = DevToolsEngineRuntime()
    runtime.tabWindows[tab.id.uuidString] = "inspect-window"
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: runtime), windowID: "inspect-window", store: store)
    engine.liveTabs.insert(tab.id)
    let target = try #require(engine.siteControlTarget)

    #expect(engine.openChromiumDeveloperTools(for: target))
    #expect(runtime.openedTabs == [tab.id.uuidString])

    let staleTarget = SiteControlTarget(
      tabID: tab.id, profileID: target.profileID, url: URL(string: "https://stale.example")!)
    #expect(!engine.openChromiumDeveloperTools(for: staleTarget))
    engine.liveTabs.remove(tab.id)
    #expect(!engine.openChromiumDeveloperTools(for: tab.id))
    #expect(runtime.openedTabs == [tab.id.uuidString])
  }
}

@MainActor
private final class DevToolsEngineRuntime: ARCChromiumRuntime {
  var tabWindows: [String: String] = [:]
  var openedTabs: [String] = []

  override func windowID(forTabID tabID: String) -> String? { tabWindows[tabID] }

  override func showDevTools(forTabID tabID: String) -> Bool {
    openedTabs.append(tabID)
    return true
  }
}
