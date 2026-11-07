// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarSourcesVisualTests: XCTestCase {
  func testMinifiedScriptPrettyPrintBeforeAfterOffscreen() async throws {
    guard ProcessInfo.processInfo.environment["SHAAR_SOURCES_PRETTY_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen pretty-print capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1435")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.test/")!)
    let script = #"const re=/https?:\/\/[^{};]+/g;function match(url){const label=`a;${url}`;return re.test(url)&&label.length>0;}"#
    let fixture = ShaarPhase2FixtureTransport { command in
      switch command {
      case .resourceTree:
        return ["items": [["url": "https://example.test/min.js", "type": "Script", "mimeType": "text/javascript"]]]
      case .resourceContent:
        return ["items": [], "body": script, "base64Encoded": false]
      default: return ["items": []]
      }
    }
    let inspector = InspectorModel(target: target, engine: nil)
    let live = ShaarDevToolsModel(target: target, phase2Transport: fixture)
    live.open(inspector: inspector)
    live.section = .sources
    for _ in 0..<20 where !live.phase2.available { await Task.yield() }
    await live.sources.refresh()
    for stage in ["before", "after"] {
      live.sources.prettyPrint = stage == "after"
      for scheme in [ColorScheme.light, .dark] {
        let suffix = scheme == .light ? "light" : "dark"
        let appearance: NSAppearance.Name = scheme == .light ? .aqua : .darkAqua
        let view = ShaarDevToolsPanel(model: live, inspector: inspector, openChromium: {})
          .frame(width: 1040, height: 600)
          .background(Color(nsColor: .windowBackgroundColor))
          .environment(\.colorScheme, scheme)
        try VisualCapture.renderOffscreen(
          view, size: NSSize(width: 1040, height: 600), appearance: appearance,
          to: root.appending(path: "\(stage)-pretty-\(suffix).png"))
      }
    }
    XCTAssertGreaterThan(live.sources.displayedLines?.count ?? 0, 5)
    live.close()
    XCTAssertTrue(NSApp.keyWindow === previous)
  }

  func testOriginalSourceMapBeforeAfterOffscreen() async throws {
    guard ProcessInfo.processInfo.environment["SHAAR_SOURCES_MAP_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen source-map capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1435")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://127.0.0.1:3211/")!)
    let map = #"{"version":3,"sources":["src/App.vue"],"sourcesContent":["<template><h1>App</h1></template>"]}"#
    let directive = "//# sourceMappingURL=data:application/json;base64,\(Data(map.utf8).base64EncodedString())"
    for mapped in [false, true] {
      let fixture = ShaarPhase2FixtureTransport { command in
        switch command {
        case .resourceTree:
          return ["items": [["url": "http://127.0.0.1:3211/src/App.vue", "type": "Script", "mimeType": "text/javascript"]]]
        case .resourceContent:
          return ["items": [], "body": "const app=1;\n" + (mapped ? directive : ""), "base64Encoded": false]
        default: return ["items": []]
        }
      }
      let inspector = InspectorModel(target: target, engine: nil)
      let live = ShaarDevToolsModel(target: target, phase2Transport: fixture)
      live.open(inspector: inspector)
      live.section = .sources
      for _ in 0..<20 where !live.phase2.available { await Task.yield() }
      await live.sources.refresh()
      XCTAssertEqual(live.sources.resources.count, mapped ? 2 : 1)
      if mapped, let original = live.sources.resources.first(where: { $0.type == "Original" }) {
        await live.sources.select(original)
        XCTAssertEqual(live.sources.content, "<template><h1>App</h1></template>")
      }
      let stage = mapped ? "after" : "before"
      for scheme in [ColorScheme.light, .dark] {
        let suffix = scheme == .light ? "light" : "dark"
        let appearance: NSAppearance.Name = scheme == .light ? .aqua : .darkAqua
        let view = ShaarDevToolsPanel(model: live, inspector: inspector, openChromium: {})
          .frame(width: 1040, height: 600)
          .background(Color(nsColor: .windowBackgroundColor))
          .environment(\.colorScheme, scheme)
        try VisualCapture.renderOffscreen(
          view, size: NSSize(width: 1040, height: 600), appearance: appearance,
          to: root.appending(path: "\(stage)-source-map-\(suffix).png"))
      }
      live.close()
    }
    XCTAssertTrue(NSApp.keyWindow === previous)
  }

  func testSourcesRenderOffscreenInBothAppearances() async throws {
    guard ProcessInfo.processInfo.environment["SHAAR_SOURCES_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen Sources capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1134")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let projectRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: projectRoot) }
    let localFile = projectRoot.appending(path: "src/Dashboard.tsx")
    try FileManager.default.createDirectory(
      at: localFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("export default function Dashboard() {}".utf8).write(to: localFile)
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/dashboard")!)
    let fixture = ShaarPhase2FixtureTransport { command in
      switch command {
      case .resourceTree:
        return [
          "items": [
            [
              "url": "http://localhost:3000/dashboard", "type": "Document", "mimeType": "text/html",
            ],
            [
              "url": "http://localhost:3000/app.js", "type": "Script",
              "mimeType": "text/javascript",
            ],
            [
              "url": "https://example.com/api/config.json", "type": "Other",
              "mimeType": "application/json",
            ],
            [
              "url": "https://example.com/styles/app.css", "type": "Stylesheet",
              "mimeType": "text/css",
            ],
          ]
        ]
      case .resourceContent(let url):
        if url.hasSuffix("app.js") {
          return [
            "items": [],
            "body": """
            import { fetchOrders } from './api';

            export default function Dashboard() {
              const orders = fetchOrders();

              return {
                title: 'Dashboard',
                count: orders.length,
              };
            }
            //# sourceMappingURL=app.js.map
            """, "base64Encoded": false,
          ]
        }
        return ["items": [], "body": "{}", "base64Encoded": false]
      default: return ["items": []]
      }
    }
    let inspector = InspectorModel(target: target, engine: nil)
    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      let pending = ShaarDevToolsModel(target: target)
      pending.section = .sources
      pending.open(inspector: inspector)
      try capture(
        ShaarDevToolsPanel(model: pending, inspector: inspector, openChromium: {}),
        named: "after-sources-unavailable-\(suffix)", scheme: scheme,
        appearance: appearance, root: root)
      pending.close()

      let live = ShaarDevToolsModel(
        target: target, phase2Transport: fixture,
        sourceLoader: { url in
          if url.path.hasSuffix("com.chrome.devtools.json") {
            return Data(#"{"workspace":{"root":"\#(projectRoot.path)"}}"#.utf8)
          }
          return Data(#"{"version":3,"sources":["webpack://_N_E/./src/Dashboard.tsx"]}"#.utf8)
        })
      live.section = .sources
      live.open(inspector: inspector)
      for _ in 0..<30 where !live.phase2.available { await Task.yield() }
      XCTAssertTrue(live.phase2.available)
      await live.sources.refresh()
      let script = try XCTUnwrap(live.sources.resources.first { $0.name == "app.js" })
      await live.sources.select(script)
      await live.sources.findLocalFiles(framework: .nextJS)
      XCTAssertEqual(live.sources.localFiles.map(\.path), [localFile.path])
      live.sources.prettyPrint = true
      live.sources.contentQuery = "Dashboard"
      live.sources.revealCurrentMatch()
      try capture(
        ShaarDevToolsPanel(model: live, inspector: inspector, openChromium: {}),
        named: "after-sources-reader-\(suffix)", scheme: scheme,
        appearance: appearance, root: root)
      live.sources.prettyPrint = false
      live.sources.contentQuery = ""
      _ = await live.sources.reveal(url: script.url, line: 3)
      try capture(
        ShaarDevToolsPanel(model: live, inspector: inspector, openChromium: {}),
        named: "after-sources-local-files-\(suffix)", scheme: scheme,
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
