// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserStoreFaviconsTests {
  @Test func privatePagesIgnoreSavedIconsButUseTheirLiveIcon() throws {
    let profileID = UUID()
    let tabID = UUID()
    let session = try BrowserSession.privateWindow(sourceProfileID: profileID, firstTabID: tabID)
    let store = BrowserStore(privateSession: session)
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = FaviconCache(directory: directory)
    cache.store(FaviconFixture.icon(.red), for: tabID, profileID: profileID)
    store.faviconCache = cache

    #expect(store.favicon(forPage: tabID) == nil)

    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: ARCChromiumRuntime()), store: store)
    defer { engine.suspensionTask?.cancel() }
    engine.memoryPressureSource?.cancel()
    engine.memoryPressureSource = nil
    engine.seedFavicon(FaviconFixture.icon(.blue), for: tabID)

    let live = try #require(store.favicon(forPage: tabID))
    #expect(FaviconFixture.matches(live, .blue))
  }
}
