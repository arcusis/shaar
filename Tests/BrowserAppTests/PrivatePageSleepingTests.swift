// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct PrivatePageSleepingTests {
  @Test func privateSleepingDownloadLookupFocusedBenchmark() throws {
    let profileID = UUID()
    let firstTabID = UUID()
    let store = BrowserStore(
      privateSession: try BrowserSession.privateWindow(
        sourceProfileID: profileID, firstTabID: firstTabID))
    for index in 0..<999 {
      _ = store.session.open(URL(string: "https://private-\(index).example")!)
    }
    let downloads = DownloadsModel()
    for index in 0..<1_000 {
      downloads.changed([
        "id": UUID().uuidString, "filename": "file-\(index)", "path": "",
        "url": "https://download.example/file", "state": DownloadState.downloading.rawValue,
        "paused": false, "dangerous": false, "offTheRecord": false,
        "received": 0.0, "total": -1.0, "startTime": Double(index),
      ], profileID: profileID)
    }
    let page = PrivatePageSession(
      runtime: ARCChromiumRuntime(), contextID: UUID().uuidString,
      windowID: UUID().uuidString, firstTabID: firstTabID, store: store,
      profileIsDownloading: { profile in
        downloads.items(in: profile).contains { $0.state == .downloading }
      })
    defer { page.stopSleepingTabWatch() }
    page.sleepingTabs.policy = {
      SleepingTabsPolicy(enabled: true, timeout: 300, neverSleepHosts: [])
    }
    page.sleepingTabs.capability = .capable
    page.memoryPressureSource?.cancel()
    page.memoryPressureSource = nil

    let start = ContinuousClock.now
    page.suspendInactiveTabs(now: Date(timeIntervalSince1970: 1_800_000_000))
    print("privateSleepingDownloadLookupFocusedBenchmark: \(start.duration(to: .now))")
    #expect(store.sleepingTabIDs.isEmpty)
  }

  @Test func lifecycleEventsSleepBackgroundTabsAndWakeActiveTabs() throws {
    let firstTabID = UUID()
    let store = BrowserStore(
      privateSession: try BrowserSession.privateWindow(
        sourceProfileID: UUID(), firstTabID: firstTabID))
    let page = PrivatePageSession(
      runtime: ARCChromiumRuntime(), contextID: UUID().uuidString,
      windowID: UUID().uuidString, firstTabID: firstTabID, store: store)
    defer { page.stopSleepingTabWatch() }
    store.perform(.open(URL(string: "https://background.example")!))

    page.applyLifecycle(firstTabID, state: "discarded", audible: false, capturing: false)
    #expect(store.sleepingTabIDs == [firstTabID])

    page.applyLifecycle(firstTabID, state: "active", audible: false, capturing: false)
    #expect(store.sleepingTabIDs.isEmpty)

    let selected = try #require(store.session.selectedPage?.tab.id)
    page.applyLifecycle(selected, state: "frozen", audible: false, capturing: false)
    #expect(store.sleepingTabIDs.isEmpty)
  }
}
