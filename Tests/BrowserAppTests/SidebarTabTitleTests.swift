// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import Testing
import Vision

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

  @Test func tabAccessibilityLabelIncludesSleepingState() {
    #expect(
      SidebarTabTitle.accessibilityLabel(
        title: "News", address: "https://news.example", isSleeping: false) == "News")
    #expect(
      SidebarTabTitle.accessibilityLabel(
        title: "News", address: "https://news.example", isSleeping: true)
        == "News, Sleeping")
  }

  @Test func tabAccessibilityLabelFallsBackToAddressForBlankTitles() {
    let address = "https://news.example/page"
    #expect(
      SidebarTabTitle.accessibilityLabel(title: "", address: address, isSleeping: false)
        == address)
    #expect(
      SidebarTabTitle.accessibilityLabel(title: " \n\t", address: address, isSleeping: false)
        == address)
    #expect(
      SidebarTabTitle.accessibilityLabel(
        title: " \n\t", address: address, isSleeping: true, isPinned: true,
        language: .english) == "\(address), Pinned, Sleeping")
  }

  @Test func tabAccessibilityLabelIncludesPinnedAndSleepingStates() {
    #expect(
      SidebarTabTitle.accessibilityLabel(
        title: "News", address: "https://news.example", isSleeping: false, isPinned: true,
        language: .english)
        == "News, Pinned")
    #expect(
      SidebarTabTitle.accessibilityLabel(
        title: "News", address: "https://news.example", isSleeping: true, isPinned: true,
        language: .english)
        == "News, Pinned, Sleeping")
    #expect(
      SidebarTabTitle.accessibilityLabel(
        title: "News", address: "https://news.example", isSleeping: false, isPinned: true,
        language: .hebrew)
        == "News, \u{2068}נעוצים\u{2069}")
  }

  @Test func tabAccessibilityLabelIncludesPinnedAndSleepingStates() {
    #expect(
      SidebarTabTitle.accessibilityLabel(
        title: "News", isSleeping: false, isPinned: true, language: .english)
        == "News, Pinned")
    #expect(
      SidebarTabTitle.accessibilityLabel(
        title: "News", isSleeping: true, isPinned: true, language: .english)
        == "News, Pinned, Sleeping")
    #expect(
      SidebarTabTitle.accessibilityLabel(
        title: "News", isSleeping: false, isPinned: true, language: .hebrew)
        == "News, \u{2068}נעוצים\u{2069}")
  }

  @Test func restingRowShowsTheFullDevToolsTitle() throws {
    let hosted = try host(title: pageTitle, closeIsVisible: false)
    defer { hosted.window.close() }
    let painted = renderedText(hosted.host)
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
    let painted = renderedText(hosted.host)
    #expect(painted.contains("Long"))
    #expect(!painted.contains(title))
  }

  private func host(title: String, closeIsVisible: Bool) throws -> HostedTabRow {
    let width = contentWidth
    let row = SidebarTabRow(
      tabID: UUID(uuidString: "30000000-0000-0000-0000-000000000099")!,
      title: title,
      address: "https://example.com",
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

  private func renderedText(_ view: NSView) -> String {
    view.layoutSubtreeIfNeeded()
    guard view.bounds.width > 1, view.bounds.height > 1,
      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { return "" }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let image = bitmap.cgImage else { return "" }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    guard (try? handler.perform([request])) != nil else { return "" }
    return (request.results ?? [])
      .compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: "\n")
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
