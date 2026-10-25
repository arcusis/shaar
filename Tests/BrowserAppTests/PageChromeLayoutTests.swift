import AppKit
import BrowserCore
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor
final class PageChromeLayoutTests: XCTestCase {
  func testMinimumPageWidthKeepsCenteredAddressAndDraggableGaps() {
    XCTAssertEqual(BrowserChromeSurfaceLayout.laneWidth, 123)
    XCTAssertEqual(BrowserChromeSurfaceLayout.addressWidth(in: 510), 236)
    XCTAssertEqual(BrowserChromeSurfaceLayout.dragGapWidth(in: 510), 14)
    XCTAssertGreaterThanOrEqual(BrowserChromeSurfaceLayout.dragGapWidth(in: 510), 12)
    XCTAssertEqual(BrowserChromeSurfaceLayout.addressWidth(in: 350), 80)
  }

  func testCapturesActualBrowserWindowChromeAcrossAccessibilityModes() async throws {
    let root = URL(
      fileURLWithPath: "/tmp/browser-page-chrome-corrected-captures", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let captures: [(String, NSAppearance.Name, Bool, Bool, Bool)] = [
      ("page-chrome-light.png", .aqua, false, false, true),
      ("page-chrome-dark.png", .darkAqua, false, false, true),
      ("page-chrome-reduced-transparency.png", .aqua, true, false, true),
      ("page-chrome-reduced-motion.png", .aqua, false, true, true),
      ("page-chrome-sidebar-hidden-minimum.png", .aqua, false, false, false),
    ]
    let store = BrowserStore()
    let longHost = "layout-proof-with-a-deliberately-long-subdomain.example.com"
    let longAddress = try XCTUnwrap(URL(string: "https://\(longHost)/ordinary/page"))
    store.perform(.open(longAddress))
    XCTAssertEqual(store.session.selectedSpace.selectedTab?.url.host(), longHost)
    var capturePixels: [String: (width: Int, height: Int)] = [:]

    for (name, appearance, reduceTransparency, reduceMotion, sidebarVisible) in captures {
      store.sidebarIsVisible = sidebarVisible
      let view = BrowserWindow(store: store)
        .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
        .environment(
          \.browserChromeAccessibilityOverrides,
          BrowserChromeAccessibilityOverrides(
            reduceTransparency: reduceTransparency, reduceMotion: reduceMotion))
      capturePixels[name] = try await capture(
        view, appearance: appearance, to: root.appending(path: name))
    }

    let captureIndex: [[String: Any]] = captures.map {
      name, appearance, reduceTransparency, reduceMotion, sidebarVisible in
      [
        "path": root.appending(path: name).path,
        "requestedWindowWidth": 760,
        "requestedWindowHeight": 520,
        "capturePixelWidth": capturePixels[name]?.width ?? 0,
        "capturePixelHeight": capturePixels[name]?.height ?? 0,
        "appearance": appearance == .darkAqua ? "dark" : "light",
        "reduceTransparency": reduceTransparency,
        "reduceMotion": reduceMotion,
        "sidebarVisible": sidebarVisible,
      ]
    }
    let proof: [String: Any] = [
      "captures": captureIndex,
      "captureMethod": "BrowserWindow hosted in hidden owned borderless NSWindow and NSHostingView",
      "selectedHost": longHost,
      "requestedContentSize": ["width": 760, "height": 520],
      "limits": [
        "No BrowserEngine attached; screenshots omit Chromium page, extension, and media state.",
        "Remote Chromium page surface and native titlebar controls are outside these captures.",
        "Accessibility modes are injected through SwiftUI environment for deterministic captures.",
      ],
    ]
    let data = try JSONSerialization.data(
      withJSONObject: proof, options: [.prettyPrinted, .sortedKeys])
    try data.write(
      to: URL(fileURLWithPath: "/tmp/browser-page-chrome-corrected-proof.json"), options: .atomic)
  }

  private func capture<V: View>(
    _ view: V, appearance: NSAppearance.Name, to url: URL
  ) async throws -> (width: Int, height: Int) {
    let host = NSHostingView(rootView: view)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: appearance)
    window.contentView = host
    defer { window.close() }

    try await Task.sleep(for: .milliseconds(300))
    host.layoutSubtreeIfNeeded()
    XCTAssertEqual(host.bounds.size, NSSize(width: 760, height: 520))
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    XCTAssertEqual(bitmap.pixelsWide, 760)
    XCTAssertEqual(bitmap.pixelsHigh, 520)
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try image.write(to: url, options: .atomic)
    return (bitmap.pixelsWide, bitmap.pixelsHigh)
  }
}
