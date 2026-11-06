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
struct NativeActivationFeedbackTests {
  @Test func acknowledgingSelectedTabDoesNotScheduleAnotherActivation() async throws {
    let store = BrowserStore()
    store.perform(.open(URL(string: "https://example.com/selected")!))
    let tab = try #require(store.session.selectedPage?.tab.id)
    let runtime = ActivationFeedbackRuntime()
    let engine = try BrowserEngine(
      events: BrowserRuntimeEvents(runtime: runtime), windowID: "feedback-window", store: store,
      presentsNativePanels: false)
    defer { engine.suspensionTask?.cancel() }
    engine.liveTabs.insert(tab)
    #expect(engine.events.router.bindTab(tab.uuidString, windowID: engine.windowID))
    runtime.onTabActivated?(tab.uuidString, store.session.selectedSpace.profileID.uuidString)
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
    #expect(runtime.activations.isEmpty)
    #expect(runtime.restoredTabs == [tab.uuidString])
  }
}

private final class ActivationFeedbackRuntime: ARCChromiumRuntime {
  nonisolated(unsafe) var activations: [String] = []
  nonisolated(unsafe) var restoredTabs: [String] = []
  override func windowID(forTabID tabID: String) -> String? { "feedback-window" }
  override func activateTabID(_ tabID: String) { activations.append(tabID) }
  override func loadProfileID(_ profileID: String, completion: @escaping (Error?) -> Void) {}
  override func view(forTabID tabID: String) -> NSView? {
    restoredTabs.append(tabID)
    return nil
  }
}
