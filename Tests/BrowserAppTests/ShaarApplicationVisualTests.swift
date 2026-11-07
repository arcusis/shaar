// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI
import XCTest

@testable import ArcusisBrowser
@testable import ShaarEngineABI

@MainActor private final class ApplicationCookieFixture: ShaarCookieStore {
  let items: [ShaarSiteCookie]
  init() {
    items = [
      [
        "name": "session", "value": "abc123", "domain": "example.com", "path": "/",
        "secure": true, "httpOnly": true, "sameSite": "Lax", "expiresUnixMs": NSNull(),
        "partitionSite": NSNull(), "partitionCrossSite": NSNull(),
        "sourceScheme": 2, "sourcePort": 443,
      ],
      [
        "name": "theme", "value": "dark", "domain": "example.com", "path": "/",
        "secure": true, "httpOnly": false, "sameSite": "Strict", "expiresUnixMs": NSNull(),
        "partitionSite": NSNull(), "partitionCrossSite": NSNull(),
        "sourceScheme": 2, "sourcePort": 443,
      ],
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
    let cacheBody = ApplicationVisualCacheBody(Data("shaar-cached-body".utf8).base64EncodedString())
    let fixture = ShaarPhase2FixtureTransport(
      events: [ApplicationWorkerFixtures.registration, ApplicationWorkerFixtures.version]
    ) { command in
      switch command {
      case .storageItems(let local, _, _):
        if local {
          return [
            "items": [
              ["key": "theme", "value": "dark"],
              ["key": "locale", "value": "en-US"],
              ["key": "feature.preview", "value": "enabled"],
            ], "hasMore": false,
          ]
        }
        return [
          "items": [
            ["key": "session-key", "value": "session-original"],
            ["key": "draft", "value": "unsaved"],
          ], "hasMore": false,
        ]
      case .indexedDBNames: return ["items": [["name": "notes"]]]
      case .indexedDBSchema: return ["items": [["name": "entries"]]]
      case .indexedDBData:
        return [
          "items": [
            ["key": "id-000", "value": "value-000"],
            ["key": "id-001", "value": "value-001"],
            ["key": "id-002", "value": "value-002"],
          ], "hasMore": true,
        ]
      case .cacheNames: return ["items": [["cacheID": "cache-1", "name": "shaar-app"]]]
      case .cacheEntries:
        return [
          "items": [
            [
              "url": "https://example.com/inspector-cached.txt", "method": "GET", "status": 200,
            ]
          ]
        ]
      case .cacheResponse:
        return ["items": [], "body": cacheBody.encoded, "base64Encoded": true]
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
      live.application.selectArea(.session)
      await live.application.refresh()
      try capture(
        ShaarDevToolsPanel(model: live, inspector: inspector, openChromium: {}),
        named: "after-application-session-\(suffix)", scheme: scheme,
        appearance: appearance, root: root)
      live.application.selectArea(.indexedDB)
      await live.application.refresh()
      live.application.selectDatabase("notes")
      await live.application.refresh()
      live.application.selectStore("entries")
      await live.application.refresh()
      live.application.selectedID = live.application.rows.first?.id
      try capture(
        ShaarDevToolsPanel(model: live, inspector: inspector, openChromium: {}),
        named: "after-application-indexeddb-\(suffix)", scheme: scheme,
        appearance: appearance, root: root)
      cacheBody.encoded = Data("shaar-cached-body".utf8).base64EncodedString()
      live.application.selectArea(.cache)
      await live.application.refresh()
      live.application.selectCache("cache-1")
      await live.application.refresh()
      live.application.selectCacheEntry("https://example.com/inspector-cached.txt")
      await live.application.refresh()
      try capture(
        ShaarDevToolsPanel(model: live, inspector: inspector, openChromium: {}),
        named: "after-application-cache-text-\(suffix)", scheme: scheme,
        appearance: appearance, root: root)
      cacheBody.encoded = Data([0x00, 0xFF, 0xFE]).base64EncodedString()
      await live.application.refresh()
      try capture(
        ShaarDevToolsPanel(model: live, inspector: inspector, openChromium: {}),
        named: "after-application-cache-binary-\(suffix)", scheme: scheme,
        appearance: appearance, root: root)
      for _ in 0..<30 where live.phase2.events.count < 2 { await Task.yield() }
      live.application.selectArea(.workers)
      await live.application.refresh()
      try capture(
        ShaarDevToolsPanel(model: live, inspector: inspector, openChromium: {}),
        named: "after-application-workers-\(suffix)", scheme: scheme,
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

@MainActor private final class ApplicationVisualCacheBody {
  var encoded: String
  init(_ encoded: String) { self.encoded = encoded }
}
