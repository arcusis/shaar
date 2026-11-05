// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct BrowserQuitReconcileTests {
  @Test func savedTabsAreNotReopenedAfterQuitStarts() throws {
    var session = BrowserSession.fresh()
    _ = session.open(URL(string: "https://example.com/pending")!)
    let store = BrowserStore(session: session)
    let runtime = QuitReconcileRuntime()
    let engine = try BrowserEngine(events: BrowserRuntimeEvents(runtime: runtime), store: store)
    defer { engine.suspensionTask?.cancel() }

    runtime.quittingForTest = true
    engine.reconcile()

    #expect(runtime.loadedProfileIDs.isEmpty)
  }
}

private final class QuitReconcileRuntime: ARCChromiumRuntime {
  nonisolated(unsafe) var quittingForTest = false
  nonisolated(unsafe) var loadedProfileIDs: [String] = []

  override var isQuitting: Bool { quittingForTest }

  override func loadProfileID(_ profileID: String, completion: @escaping (Error?) -> Void) {
    loadedProfileIDs.append(profileID)
  }
}
