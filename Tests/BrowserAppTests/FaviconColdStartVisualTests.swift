// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI
import XCTest

@testable import ArcusisBrowser

/// Restores a saved workspace without loading any page and renders its sidebar, once with an
/// empty favicon cache and once with the icons saved by the previous launch.
@MainActor
final class FaviconColdStartVisualTests: XCTestCase {
  private let iconColors: [NSColor] = [
    NSColor(srgbRed: 0.86, green: 0.18, blue: 0.18, alpha: 1),
    NSColor(srgbRed: 0.16, green: 0.62, blue: 0.30, alpha: 1),
    NSColor(srgbRed: 0.15, green: 0.40, blue: 0.85, alpha: 1),
    NSColor(srgbRed: 0.95, green: 0.60, blue: 0.10, alpha: 1),
  ]
  private let pinnedColor = NSColor(srgbRed: 0.55, green: 0.25, blue: 0.75, alpha: 1)

  func testFavoritesGridShowsCachedIconsAfterColdStart() async throws {
    let root = URL(fileURLWithPath: "/tmp/browser-favicon-cold-start", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let support = FileManager.default.temporaryDirectory.appending(
      path: "favicon-cold-start-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: support) }
    let file = WorkspaceFile(
      url: support.appending(path: "workspace.json"),
      legacySessionURL: support.appending(path: "session.json"))
    let favicons = support.appending(path: "favicons")
    try recordIconsInPreviousLaunch(file: file, favicons: favicons)

    let uncached = try await captureColdStart(
      file: file, favicons: support.appending(path: "empty-favicons"),
      to: root.appending(path: "cold-start-without-cache.png"))
    let cached = try await captureColdStart(
      file: file, favicons: favicons, to: root.appending(path: "cold-start-with-cache.png"))

    for color in iconColors + [pinnedColor] {
      XCTAssertEqual(pixelCount(of: color, in: uncached), 0)
      XCTAssertGreaterThan(pixelCount(of: color, in: cached), 150, "Icon missing: \(color)")
    }
  }

  /// Reports icons the way the engine does while the previous launch had its pages loaded.
  private func recordIconsInPreviousLaunch(file: WorkspaceFile, favicons: URL) throws {
    let manager = try BrowserWorkspaceStore(
      file: file, initialSession: sidebarSession(),
      faviconCache: FaviconCache(directory: favicons))
    let store = try XCTUnwrap(manager.stores[manager.workspace.windows[0].id])
    for (favorite, color) in zip(store.profileFavorites, iconColors) {
      let page = try XCTUnwrap(store.session.favoritePage(for: favorite.id))
      store.rememberFavicon(FaviconFixture.icon(color), forTab: page.tab.id)
    }
    let pinned = try XCTUnwrap(store.session.selectedSpace.tabs.first { $0.isPinned })
    store.rememberFavicon(FaviconFixture.icon(pinnedColor), forTab: pinned.id)
  }

  private func captureColdStart(file: WorkspaceFile, favicons: URL, to url: URL) async throws
    -> NSBitmapImageRep
  {
    let manager = try BrowserWorkspaceStore(
      file: file, faviconCache: FaviconCache(directory: favicons))
    let store = try XCTUnwrap(manager.stores[manager.workspace.windows[0].id])
    XCTAssertNil(store.engine)
    let size = NSSize(width: 240, height: 520)
    let host = NSHostingView(
      rootView: BrowserSidebar(store: store)
        .frame(width: size.width, height: size.height)
        .background(Color(nsColor: .windowBackgroundColor)))
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    host.frame = NSRect(origin: .zero, size: size)
    defer { window.close() }

    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    return try VisualCapture.render(host, to: url)
  }

  private func sidebarSession() -> BrowserSession {
    var session = BrowserSession.fresh()
    let profileID = session.selectedSpace.profileID
    for name in ["mail", "calendar", "docs", "news"] {
      _ = session.addFavorite(
        profileID: profileID, originalURL: URL(string: "https://\(name).example")!,
        title: name.capitalized)
    }
    let pinnedID = session.open(URL(string: "https://pinned.example")!)!
    session.togglePin(pinnedID)
    _ = session.open(URL(string: "https://ordinary.example")!)
    return session
  }

  private func pixelCount(of color: NSColor, in bitmap: NSBitmapImageRep) -> Int {
    guard let wanted = color.usingColorSpace(.sRGB) else { return 0 }
    var count = 0
    for x in 0..<bitmap.pixelsWide {
      for y in 0..<bitmap.pixelsHigh {
        guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        let distance = max(
          abs(pixel.redComponent - wanted.redComponent),
          abs(pixel.greenComponent - wanted.greenComponent),
          abs(pixel.blueComponent - wanted.blueComponent))
        if distance < 0.08 { count += 1 }
      }
    }
    return count
  }
}
