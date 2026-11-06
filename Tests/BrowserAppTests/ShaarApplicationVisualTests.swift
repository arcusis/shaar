// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import ShaarEngineABI
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor private final class ApplicationCookieFixture: ShaarCookieStore {
  let items: [ShaarSiteCookie]
  init() {
    items = [
      ["name": "session", "value": "abc123", "domain": "example.com", "path": "/",
       "secure": true, "httpOnly": true, "sameSite": "Lax", "expiresUnixMs": NSNull(),
       "partitionSite": NSNull(), "partitionCrossSite": NSNull(),
       "sourceScheme": 2, "sourcePort": 443],
      ["name": "theme", "value": "dark", "domain": "example.com", "path": "/",
       "secure": true, "httpOnly": false, "sameSite": "Strict", "expiresUnixMs": NSNull(),
       "partitionSite": NSNull(), "partitionCrossSite": NSNull(),
       "sourceScheme": 2, "sourcePort": 443],
    ].compactMap(ShaarSiteCookie.init(dictionary:))
  }
  func siteCookies(for target: SiteControlTarget) async throws -> [ShaarSiteCookie] { items }
  func setSiteCookie(
    _ cookie: ShaarSiteCookie, value: String, secure: Bool, httpOnly: Bool,
    sameSite: ShaarCookieSameSite, for target: SiteControlTarget
  ) async throws {}
  func deleteSiteCookie(_ cookie: ShaarSiteCookie, for target: SiteControlTarget) async throws {}
}

@MainActor final class ShaarApplicationVisualTests: XCTestCase {
  func testApplicationRendersOffscreenInBothAppearances() async throws {
    guard ProcessInfo.processInfo.environment["SHAAR_APPLICATION_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen Application capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1134")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com/dashboard")!)
    let fixture = ShaarPhase2FixtureTransport { command in
      switch command {
      case .storageItems:
        return [
          "items": [
            ["key": "theme", "value": "dark"],
            ["key": "locale", "value": "en-US"],
            ["key": "feature.preview", "value": "enabled"],
          ], "hasMore": false,
        ]
      case .indexedDBNames: return ["items": [["name": "notes"]]]
      case .cacheNames: return ["items": [["cacheID": "cache-1", "name": "v1"]]]
      default: return ["items": []]
      }
    }
    let inspector = InspectorModel(target: target, engine: nil)
    let cookieFixture = ApplicationCookieFixture()
    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      let pending = ShaarDevToolsModel(target: target)
      pending.section = .application
      pending.open(inspector: inspector)
      try capture(
        ShaarDevToolsPanel(model: pending, inspector: inspector, openChromium: {}),
        named: "after-application-cookie-unavailable-\(suffix)", scheme: scheme,
        appearance: appearance, root: root)
      pending.close()

      let live = ShaarDevToolsModel(target: target, phase2Transport: fixture)
      live.section = .application
      live.open(inspector: inspector)
      for _ in 0..<30 where !live.phase2.available { await Task.yield() }
      XCTAssertTrue(live.phase2.available)
      live.application.selectArea(.local)
      await live.application.refresh()
      try capture(
        ShaarDevToolsPanel(model: live, inspector: inspector, openChromium: {}),
        named: "after-application-storage-\(suffix)", scheme: scheme,
        appearance: appearance, root: root)
      live.application.selectArea(.cookies)
      live.cookies.configure(store: cookieFixture, target: target)
      await live.cookies.refresh()
      live.cookies.selectedID = live.cookies.cookies.first?.id
      try capture(
        ShaarDevToolsPanel(
          model: live, inspector: inspector, openChromium: {}, cookieStore: cookieFixture),
        named: "after-application-cookie-items-\(suffix)", scheme: scheme,
        appearance: appearance, root: root)
      live.close()
    }
    XCTAssertTrue(NSApp.keyWindow === previous)
  }

  private func capture<V: View>(
    _ panel: V, named name: String, scheme: ColorScheme, appearance: NSAppearance.Name,
    root: URL
  ) throws {
    let view =
      panel
      .frame(width: 1040, height: 440)
      .background(Color(nsColor: .windowBackgroundColor))
      .environment(\.colorScheme, scheme)
    let image = try VisualCapture.renderOffscreen(
      view, size: NSSize(width: 1040, height: 440), appearance: appearance,
      to: root.appending(path: "\(name).png"))
    XCTAssertEqual(image.pixelsWide, 1040)
    XCTAssertEqual(image.pixelsHigh, 440)
  }
}
