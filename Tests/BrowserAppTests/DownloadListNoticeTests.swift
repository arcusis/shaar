// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct DownloadListNoticeTests {
  @Test func restoredListClearsOnlyTheUnavailableNotice() throws {
    let runtime = ARCShaarRuntime()
    let events = BrowserRuntimeEvents(runtime: runtime)
    let store = BrowserStore()
    let engine = try BrowserEngine(events: events, windowID: "window", store: store)
    let profile = try #require(store.session.profiles.first?.id.uuidString)
    let unavailable = BrowserEngine.downloadListUnavailableNotice

    runtime.onNotice?(unavailable)
    #expect(engine.notice == unavailable)
    runtime.onDownloadsRestored?(profile, [])
    #expect(engine.notice == nil)

    let unrelated = "A saved tab already belongs to another window."
    runtime.onNotice?(unrelated)
    runtime.onDownloadsRestored?(profile, [])
    #expect(engine.notice == unrelated)

    runtime.onNotice?(unavailable)
    runtime.onDownloadsRestored?(UUID().uuidString, [])
    #expect(engine.notice == unavailable)
  }
}
