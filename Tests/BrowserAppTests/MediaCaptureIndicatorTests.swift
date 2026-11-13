// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ChromiumBridge
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct MediaCaptureIndicatorTests {
  @Test func indicatorAppearsAfterAWindowOwnedCaptureEvent() throws {
    var session = BrowserSession.fresh()
    let opened = session.open(URL(string: "https://capture.example")!)
    #expect(opened != nil)
    let store = BrowserStore(session: session)
    let tabID = try #require(store.session.selectedPage?.tab.id)
    let runtime = CaptureIndicatorTestRuntime()
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: runtime), windowID: "capture-window", store: store)
    defer { engine.memoryPressureSource?.cancel() }
    engine.memoryPressureSource?.cancel()
    engine.memoryPressureSource = nil
    #expect(engine.events.router.bindTab(tabID.uuidString, windowID: engine.windowID))

    let host = NSHostingView(rootView: MediaCaptureIndicator(store: store, engine: engine))
    host.frame = NSRect(x: 0, y: 0, width: 320, height: 40)
    host.layoutSubtreeIfNeeded()
    let emptySize = host.fittingSize

    runtime.onMediaAccess?(tabID.uuidString, ["camera": true])
    host.layoutSubtreeIfNeeded()

    #expect(host.fittingSize.width > emptySize.width)
    #expect(host.fittingSize.height > 0)
  }
}

@MainActor
private final class CaptureIndicatorTestRuntime: ARCShaarRuntime {
  override func windowID(forTabID tabID: String) -> String? { "capture-window" }
}
