// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct SidebarTabTitleTests {
  private let pageTitle = "Shaar DevTools QA"
  /// BrowserSidebar pads 14pt on each side of the 200pt column.
  private var contentWidth: CGFloat { BrowserChromeLayout.sidebarWidth - 28 }

  @Test func midwordClipMatchesTheCutTitleOnly() {
    #expect(SidebarTabTitle.isMidwordClip("Shaar DevToo…"))
    #expect(SidebarTabTitle.isMidwordClip("sidebar\nShaar DevToo"))
    #expect(!SidebarTabTitle.isMidwordClip("Shaar DevTools QA"))
    #expect(!SidebarTabTitle.isMidwordClip("Shaar DevTools"))
    #expect(SidebarTabTitle.showsFullTitle("Shaar DevTools QA"))
    #expect(SidebarTabTitle.showsFullTitle("The tab reads Shaar DevTools."))
    #expect(!SidebarTabTitle.showsFullTitle("Shaar DevToo…"))
  }

  @Test func restingRowShowsTheFullDevToolsTitle() throws {
    let hosted = try host(title: pageTitle, closeIsVisible: false)
    defer { hosted.window.close() }
    let painted = ShaarDevToolsSmokeAccess.renderedText(hosted.host)
    #expect(SidebarTabTitle.showsFullTitle(painted), "painted: \(painted)")
    #expect(!SidebarTabTitle.isMidwordClip(painted), "painted: \(painted)")
    #expect(!hosted.window.isVisible)
  }

  @Test func closeButtonStaysInsideTheRow() throws {
    let hosted = try host(title: pageTitle, closeIsVisible: true)
    defer { hosted.window.close() }
    #expect(fits(hosted.host, width: contentWidth))
    #expect(!hosted.window.isVisible)
  }

  @Test func longTitleDoesNotWidenTheRow() throws {
    let title = String(repeating: "Long ordinary tab label ", count: 6)
    let hosted = try host(title: title, closeIsVisible: false)
    defer { hosted.window.close() }
    #expect(fits(hosted.host, width: contentWidth))
    let painted = ShaarDevToolsSmokeAccess.renderedText(hosted.host)
    #expect(painted.contains("Long"))
    #expect(!painted.contains(title))
  }

  private func host(title: String, closeIsVisible: Bool) throws -> HostedTabRow {
    let width = contentWidth
    let row = SidebarTabRow(
      tabID: UUID(uuidString: "30000000-0000-0000-0000-000000000099")!,
      title: title,
      favicon: nil,
      isPinned: false,
      isSelected: true,
      closeIsVisible: closeIsVisible,
      onSelect: {},
      onClose: {},
      onHoverChanged: { _ in }
    )
    .frame(width: width, height: 48)
    .background(Color(nsColor: .windowBackgroundColor))
    let size = NSSize(width: width, height: 48)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    let host = NSHostingView(rootView: row)
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    host.layoutSubtreeIfNeeded()
    return HostedTabRow(window: window, host: host)
  }

  private func fits(_ view: NSView, width: CGFloat) -> Bool {
    guard view.bounds.width <= width + 1 else { return false }
    for child in view.subviews where !fits(child, width: width - child.frame.minX) {
      return false
    }
    return true
  }
}

private struct HostedTabRow {
  let window: NSWindow
  let host: NSView
}
