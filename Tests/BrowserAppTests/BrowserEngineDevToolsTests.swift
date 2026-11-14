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
    #expect(
      BrowserEngine.extensionInstallRefreshDelaysMilliseconds == [250, 750, 1_500, 3_000, 4_500])
  }

  @Test func reconcileTabOrderingBenchmark() {
    let tabs = (0..<5_000).map { index in
      BrowserTab(url: URL(string: "https://example.test/\(index)")!, isPinned: index < 2_500)
    }
    let favorites = (0..<100).map { index in
      BrowserTab(url: URL(string: "https://favorite.test/\(index)")!)
    }

    let beforeStart = ContinuousClock.now
    var beforeCount = 0
    var beforeOrder: [BrowserTab] = []
    for _ in 0..<100 {
      beforeOrder = tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned } + favorites
      beforeCount += beforeOrder.count
    }
    let before = beforeStart.duration(to: .now)

    let afterStart = ContinuousClock.now
    var afterCount = 0
    var afterOrder: [BrowserTab] = []
    for _ in 0..<100 {
      afterOrder = BrowserEngine.orderedTabs(tabs, favorites: favorites)
      afterCount += afterOrder.count
    }
    let after = afterStart.duration(to: .now)
    print("reconcileTabOrderingBenchmark: before=\(before), after=\(after)")
    #expect(beforeCount == afterCount)
    #expect(beforeOrder == afterOrder)
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

  @Test func extensionExecutionFailureUsesLocalizedRecoveryCopy() throws {
    let store = BrowserStore()
    store.perform(.open(try #require(URL(string: "https://extensions.example/"))))
    let runtime = DevToolsEngineRuntime()
    runtime.extensionExecutionError = NSError(domain: "ExtensionBackend", code: 7)
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: runtime), windowID: "extension-window", store: store)

    engine.executeExtension("extension-id")

    #expect(engine.notice == "Could not run the extension. Try again.")
    #expect(
      BrowserLocalization.string(
        "Could not run the extension. Try again.", table: "Panels", language: .hebrew)
        == "לא ניתן להפעיל את התוסף. כדאי לנסות שוב.")
  }

  @Test func developerToolsFailureUsesLocalizedNotice() throws {
    let store = BrowserStore()
    store.perform(.open(try #require(URL(string: "https://inspect.example/page"))))
    let tab = try #require(store.session.selectedSpace.selectedTab)
    let runtime = DevToolsEngineRuntime()
    runtime.tabWindows[tab.id.uuidString] = "inspect-window"
    runtime.toggleError = NSError(domain: "DevTools", code: 1, userInfo: [NSLocalizedDescriptionKey: "The engine refused."])
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: runtime), windowID: "inspect-window", store: store)
    engine.liveTabs.insert(tab.id)

    engine.toggleChromiumDeveloperTools()

    #expect(engine.notice == ShellL10n.string("Could not open developer tools. Try again."))
  }
}

@MainActor
private final class DevToolsEngineRuntime: ARCChromiumRuntime {
  nonisolated(unsafe) var tabWindows: [String: String] = [:]
  nonisolated(unsafe) var openedTabs: [String] = []
  nonisolated(unsafe) var extensionExecutionError: Error?
  var toggleError: Error?

  override func windowID(forTabID tabID: String) -> String? {
    tabWindows[tabID]
  }

  override func showDevTools(forTabID tabID: String) -> Bool {
    openedTabs.append(tabID)
    return true
  }

  override func executeExtensionID(_ extensionID: String, tabID: String) throws {
    if let extensionExecutionError { throw extensionExecutionError }
  }

  @MainActor override func toggleDevTools(
    forTabID tabID: String, completion: @escaping @MainActor @Sendable (Error?) -> Void
  ) {
    completion(toggleError)
  }
}
