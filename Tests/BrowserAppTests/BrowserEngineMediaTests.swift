// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserEngineMediaTests {
  @Test func mediaSessionUpdatesAreIgnoredWhenNativeWindowOwnershipDoesNotMatch() throws {
    let store = BrowserStore()
    store.perform(.open(try #require(URL(string: "https://first.example/music"))))
    let firstTab = try #require(store.session.selectedSpace.selectedTab?.id)
    store.perform(.open(try #require(URL(string: "https://second.example/music"))))
    let secondTab = try #require(store.session.selectedSpace.selectedTab?.id)

    let runtime = MediaOwnershipRuntime()
    runtime.tabWindows = [
      firstTab.uuidString: "other-window", secondTab.uuidString: "owner-window",
    ]
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: runtime), windowID: "owner-window", store: store)
    engine.liveTabs.formUnion([firstTab, secondTab])
    store.media.update(
      firstTab, state: MediaSessionState(playbackState: .playing, title: "Original"))

    engine.receiveMediaSession(
      firstTab.uuidString, payload: ["playbackState": "playing", "title": "Foreign update"])
    #expect(store.media.sessions[firstTab]?.title == "Original")

    engine.receiveMediaSession(
      secondTab.uuidString, payload: ["playbackState": "playing", "title": "Owned update"])
    #expect(store.media.sessions[secondTab]?.title == "Owned update")
  }
}

@MainActor
private final class MediaOwnershipRuntime: ARCChromiumRuntime {
  nonisolated(unsafe) var tabWindows: [String: String] = [:]

  override func windowID(forTabID tabID: String) -> String? { tabWindows[tabID] }
}
