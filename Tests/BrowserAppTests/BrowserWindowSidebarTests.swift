// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct BrowserWindowSidebarTests {
  @Test func pinChangesUpdateAnExistingOffscreenWindow() async throws {
    let store = BrowserStore(sessionFile: nil)
    let content = BrowserWindow(store: store).transaction {
      $0.animation = nil
      $0.disablesAnimations = true
    }
    let host = NSHostingView(rootView: Optional(content))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer {
      host.rootView = nil
      window.contentView = nil
      window.close()
    }
    func rendered() async throws -> Data {
      try await Task.sleep(for: .milliseconds(150))
      host.layoutSubtreeIfNeeded()
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      #expect(host.bounds.size == NSSize(width: 1000, height: 720))
      #expect(!window.isVisible && !window.isKeyWindow && !window.isMainWindow)
      return try #require(bitmap.representation(using: .png, properties: [:]))
    }
    let pinned = try await rendered()
    store.sidebarIsVisible = false
    let hidden = try await rendered()
    #expect(hidden != pinned)
    store.sidebarIsVisible = true
    let repinned = try await rendered()
    #expect(repinned != hidden)
    #expect(store.sidebarIsVisible)
  }
}
