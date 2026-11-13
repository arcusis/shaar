// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import ChromiumBridge
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor
struct PrivateBrowserHostTests {
  @Test func activeOwnerTracksTheKeyWindowAndIgnoresUnownedWindows() throws {
    let runtime = PrivateBrowserHostTestRuntime()
    var keyWindow: NSWindow?
    let host = PrivateBrowserHost(
      runtime: runtime, presentsWindows: false,
      keyWindow: { keyWindow }, sourceProfileID: { UUID().uuidString })

    #expect(host.activeOwner == nil)
    #expect(!host.hasActiveWindow)

    try host.openWindow()
    let owner = try #require(host.ownedWindows.first)
    let unrelatedWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
      styleMask: [.titled], backing: .buffered, defer: false)

    keyWindow = unrelatedWindow
    #expect(host.activeOwner == nil)
    #expect(!host.hasActiveWindow)

    keyWindow = owner.window
    #expect(host.activeOwner?.windowID == owner.windowID)
    #expect(host.hasActiveWindow)

    host.detach()
  }
}

@MainActor
private final class PrivateBrowserHostTestRuntime: ARCChromiumRuntime {
  nonisolated(unsafe) private var windows: [String: NSWindow] = [:]
  nonisolated(unsafe) private var containers: [String: NSView] = [:]

  override func createPrivateContextID(
    _ contextID: String, sourceProfileID: String,
    completion: @escaping @MainActor @Sendable (Bool, Error?) -> Void
  ) {
    completion(true, nil)
  }

  override func createPrivateWindowID(
    _ windowID: String, contextID: String, tabID: String, url: String
  ) throws {
    windows[windowID] = MainActor.assumeIsolated {
      NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    }
    containers[windowID] = MainActor.assumeIsolated {
      NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    }
  }

  override func window(forPrivateWindowID windowID: String, contextID: String) -> NSWindow? {
    windows[windowID]
  }

  override func hostView(forPrivateWindowID windowID: String, contextID: String) -> NSView? {
    containers[windowID]
  }
}
