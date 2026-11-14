// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI
import Testing

@testable import ArcusisBrowser

private final class OffscreenKeyEligibleWindow: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

@Suite @MainActor struct BrowserWindowSidebarTests {
  @Test func pinnedSidebarGroupIsAHeading() {
    #expect(BrowserSidebar.pinnedSectionHeadingTraits == .isHeader)
  }

  @Test func currentSidebarTabsGroupIsALocalizedHeading() {
    #expect(BrowserSidebar.currentTabsSectionHeadingTraits == .isHeader)
    #expect(BrowserSidebar.currentTabsSectionLabel(language: .english) == "Today's tabs")
    #expect(BrowserSidebar.currentTabsSectionLabel(language: .hebrew) == "לשוניות היום")
  }

  @Test func sidebarGroupLabelIsLocalized() {
    #expect(BrowserSidebar.accessibilityGroupLabel(language: .english) == "Browser sidebar")
    #expect(BrowserSidebar.accessibilityGroupLabel(language: .hebrew) == "סרגל הצד של הדפדפן")
  }

  @Test func reduceMotionCombinesTheSystemSettingAndAccessibilityOverride() {
    #expect(BrowserWindow.reduceMotionEnabled(systemSetting: false, override: nil) == false)
    #expect(BrowserWindow.reduceMotionEnabled(systemSetting: false, override: true) == true)
    #expect(BrowserWindow.reduceMotionEnabled(systemSetting: true, override: false) == true)
    #expect(BrowserWindow.reduceMotionEnabled(systemSetting: true, override: nil) == true)
  }

  @Test func compactScreenDoesNotRequireOversizedBrowserContent() {
    let store = BrowserStore(sessionFile: nil)
    let size = NSSize(width: 620, height: 480)
    let host = NSHostingView(rootView: BrowserWindow(store: store))
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer {
      window.contentView = nil
      window.close()
    }
    host.layoutSubtreeIfNeeded()

    #expect(host.fittingSize.width <= size.width)
    #expect(host.fittingSize.height <= size.height)
    #expect(!window.isVisible && !window.isKeyWindow && !window.isMainWindow)
  }

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

  @Test func openingPaneCommandMakesSearchFieldFirstResponderOffscreen() async throws {
    var session = BrowserSession.fresh()
    let firstResult = session.open(URL(string: "https://first.example")!)
    let secondResult = session.open(URL(string: "https://second.example")!)
    let first = try #require(firstResult)
    let second = try #require(secondResult)
    let didSplit = session.splitTabs(first, second, in: session.selectedSpaceID)
    #expect(didSplit)
    let store = BrowserStore(session: session)
    let size = NSSize(width: 900, height: 600)
    let host = NSHostingView(rootView: BrowserWindow(store: store))
    let window = OffscreenKeyEligibleWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer {
      window.contentView = nil
      window.close()
    }
    host.layoutSubtreeIfNeeded()

    #expect(window.canBecomeKey && window.canBecomeMain)
    #expect(!window.isVisible && !window.isKeyWindow && !window.isMainWindow)
    // This is the action wired to the pane + button.
    store.openSplitPane(beside: first, edge: .right)
    // A delayed hosted sleep must not consume the entire focus readiness window.
    for _ in 0..<40 {
      if window.firstResponder is NSTextView { break }
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(50))
    }

    #expect(store.commandIsOpen)
    #expect(window.firstResponder is NSTextView)
    #expect(!window.isVisible && !window.isKeyWindow && !window.isMainWindow)
  }
}
