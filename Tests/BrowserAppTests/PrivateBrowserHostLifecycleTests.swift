// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@MainActor
private final class PrivateHostLifecycleRuntime: ARCChromiumRuntime {
  nonisolated(unsafe) var windows: [String: NSWindow] = [:]
  nonisolated(unsafe) var containers: [String: NSView] = [:]
  nonisolated(unsafe) var createdContexts: [String] = []
  nonisolated(unsafe) var releasedContexts: [String] = []

  override func createPrivateContextID(
    _ contextID: String, sourceProfileID: String,
    completion: @escaping @MainActor @Sendable (Bool, Error?) -> Void
  ) {
    createdContexts.append(contextID)
    completion(true, nil)
  }

  override func createPrivateWindowID(
    _ windowID: String, contextID: String, tabID: String, url: String
  ) throws {
    let window = MainActor.assumeIsolated {
      NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    }
    let container = MainActor.assumeIsolated {
      NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }
    windows[windowID] = window
    containers[windowID] = container
  }

  override func window(forPrivateWindowID windowID: String, contextID: String) -> NSWindow? {
    windows[windowID]
  }

  override func hostView(forPrivateWindowID windowID: String, contextID: String) -> NSView? {
    containers[windowID]
  }

  override func releasePrivateContextID(_ contextID: String) -> Bool {
    releasedContexts.append(contextID)
    return true
  }
}

@Suite @MainActor
struct PrivateBrowserHostLifecycleTests {
  @Test func closingOneOfSeveralPrivateWindowsKeepsContextUntilTheLastWindowCloses() throws {
    let runtime = PrivateHostLifecycleRuntime()
    let sourceProfileID = UUID().uuidString
    let host = PrivateBrowserHost(
      runtime: runtime, presentsWindows: false,
      sourceProfileID: { sourceProfileID })
    host.installCallbacks()

    try host.openWindow()
    try host.openWindow()
    let owners = host.ownedWindows
    #expect(owners.count == 2)
    #expect(Set(owners.map(\.contextID)).count == 1)
    let contextID = try #require(owners.first?.contextID)

    runtime.onPrivateWindowClosed?(contextID, owners[0].windowID)
    #expect(host.windowCount == 1)
    #expect(runtime.releasedContexts.isEmpty)

    runtime.onPrivateWindowClosed?(contextID, owners[1].windowID)
    #expect(host.windowCount == 0)
    #expect(runtime.releasedContexts == [contextID])
    host.detach()
  }
}
