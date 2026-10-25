import AppKit
import BrowserCore
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor
final class CommandPanelSurfaceTests: XCTestCase {
  func testCapturesOpaqueAdaptiveCommandPanelAtMinimumAndWithLongUnicodeResult() async throws {
    let root = URL(fileURLWithPath: "/tmp/browser-command-panel-surface", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = BrowserStore()
    for index in 0..<7 {
      store.perform(.open(URL(string: "https://surface-example-\(index).example/path")!))
    }
    store.showCommand()
    let layoutContent = CGRect(x: 240, y: 45, width: 510, height: 465)
    let panelFrame = BrowserChromeLayout.commandPanelFrame(
      in: layoutContent, resultCount: store.results.count)
    XCTAssertEqual(panelFrame.midX, layoutContent.midX)
    XCTAssertEqual(panelFrame.midY, layoutContent.midY)
    XCTAssertLessThanOrEqual(panelFrame.width, layoutContent.width)
    XCTAssertLessThanOrEqual(panelFrame.height, layoutContent.height)
    let resultsHeight = BrowserChromeLayout.commandResultsHeight(
      resultCount: store.results.count, availableHeight: panelFrame.height)

    let bright = try await capture(
      canvas(
        panel(store: store, width: panelFrame.width, resultsHeight: resultsHeight),
        background: .white),
      size: NSSize(width: 760, height: 520), appearance: .aqua,
      to: root.appending(path: "opaque-over-bright.png"))
    let darkContent = try await capture(
      canvas(
        panel(store: store, width: panelFrame.width, resultsHeight: resultsHeight),
        background: .black),
      size: NSSize(width: 760, height: 520), appearance: .aqua,
      to: root.appending(path: "opaque-over-dark.png"))
    XCTAssertEqual(try interiorPixel(bright), try interiorPixel(darkContent))

    let darkAppearance = try await capture(
      canvas(
        panel(store: store, width: panelFrame.width, resultsHeight: resultsHeight)
          .environment(\.colorScheme, .dark),
        background: .black),
      size: NSSize(width: 760, height: 520), appearance: .darkAqua,
      to: root.appending(path: "dark-appearance.png"))
    XCTAssertNotEqual(try interiorPixel(bright), try interiorPixel(darkAppearance))

    store.commandQuery = String(repeating: "長い検索語🌿界", count: 18)
    store.commandSelection = 0
    let longResultHeight = BrowserChromeLayout.commandResultsHeight(
      resultCount: store.results.count, availableHeight: panelFrame.height)
    _ = try await capture(
      canvas(
        panel(store: store, width: panelFrame.width, resultsHeight: longResultHeight),
        background: Color(nsColor: .windowBackgroundColor)),
      size: NSSize(width: 760, height: 520), appearance: .aqua,
      to: root.appending(path: "minimum-long-unicode-result.png"))
  }

  private func panel(store: BrowserStore, width: CGFloat, resultsHeight: CGFloat) -> some View {
    CommandPanel(store: store, resultsHeight: resultsHeight)
      .frame(width: width)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func canvas<V: View>(_ panel: V, background: Color) -> some View {
    ZStack {
      background.ignoresSafeArea()
      panel.position(x: 495, y: 277.5)
    }
    .frame(width: 760, height: 520)
  }

  private func capture<V: View>(
    _ view: V, size: NSSize, appearance: NSAppearance.Name, to url: URL
  ) async throws -> NSBitmapImageRep {
    let host = NSHostingView(rootView: view)
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: appearance)
    window.contentView = host
    defer { window.close() }

    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    XCTAssertEqual(host.bounds.size, size)
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
      to: url, options: .atomic)
    return bitmap
  }

  private func interiorPixel(_ bitmap: NSBitmapImageRep) throws -> NSColor {
    let x = 240 + 510 - 16
    let y = bitmap.pixelsHigh / 2
    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
    return try XCTUnwrap(color.usingColorSpace(.deviceRGB))
  }
}
