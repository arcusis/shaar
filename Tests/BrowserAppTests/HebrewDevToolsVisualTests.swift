// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import BrowserCore
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class HebrewDevToolsVisualTests: XCTestCase {
  func testHebrewDevToolsPanelsRenderOffscreenInBothAppearances() async throws {
    guard ProcessInfo.processInfo.environment["SHAAR_HEBREW_DEVTOOLS_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen Hebrew DevTools capture requires explicit opt-in")
    }
    var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    arguments[BrowserLanguage.selectionDefaultsKey] = BrowserLanguage.hebrew.rawValue
    UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    XCTAssertEqual(BrowserLanguage.currentLaunchLanguage, .hebrew)
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1241")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(),
      url: URL(string: "http://localhost:3000/dashboard?lang=he")!)
    let fixture: [ShaarDevToolsEvent] = [
      .console(
        ShaarConsoleEvent(
          id: UUID(), level: .error, message: "GET /api/items failed: 503",
          source: "/app/items.ts:18", origin: .server)),
      .network(
        ShaarNetworkEvent(
          id: UUID(), method: "GET", url: "http://localhost:3000/api/items?limit=20",
          status: 503, mimeType: "application/json", encodedBytes: 34, time: 0.18,
          requestHeaders: [.init(name: "accept", value: "application/json")],
          responseHeaders: [.init(name: "content-type", value: "application/json")],
          responseBody: "{\"error\":\"upstream unavailable\"}")),
    ]
    let inspector = InspectorModel(target: target, engine: nil)
    inspector.open()
    try inspector.receive(InspectorPanelTests.fixtureSelection())
    let shell = ShaarDevToolsModel(
      target: target, transport: ShaarDevToolsFixtureTransport(fixture: fixture))
    shell.open(inspector: inspector)
    for _ in 0..<30 where shell.events.count < fixture.count { await Task.yield() }
    XCTAssertTrue(shell.streamAvailable)
    shell.network.selectedID = shell.network.requests(from: shell.events).first?.id
    shell.network.detailTab = .response
    shell.console.selectedID = shell.console.rows(from: shell.events).first?.id

    for scheme in [ColorScheme.light, .dark] {
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      let suffix = scheme == .dark ? "dark" : "light"
      try capture(
        InspectorPanel(model: inspector)
          .frame(width: 1040, height: 620)
          .environment(\.colorScheme, scheme).shellLocalization(),
        named: "before-inspector-hebrew-\(suffix)", appearance: appearance, root: root)
      shell.section = .console
      try capture(
        ShaarDevToolsPanel(model: shell, inspector: inspector, openChromium: {})
          .frame(width: 1040, height: 620)
          .environment(\.colorScheme, scheme).shellLocalization(),
        named: "after-console-hebrew-\(suffix)", appearance: appearance, root: root)
      shell.section = .network
      try capture(
        ShaarDevToolsPanel(model: shell, inspector: inspector, openChromium: {})
          .frame(width: 1040, height: 620)
          .environment(\.colorScheme, scheme).shellLocalization(),
        named: "after-network-hebrew-\(suffix)", appearance: appearance, root: root)
      for (section, name) in [
        (ShaarDevToolsSection.application, "application"),
        (.performance, "performance"), (.sources, "sources"), (.repro, "repro"),
        (.viewports, "viewports"),
      ] {
        shell.section = section
        try capture(
          ShaarDevToolsPanel(model: shell, inspector: inspector, openChromium: {})
            .frame(width: 1040, height: 620)
            .environment(\.colorScheme, scheme).shellLocalization(),
          named: "after-\(name)-hebrew-\(suffix)", appearance: appearance, root: root)
      }
      let developer = DeveloperPageModel(target: target, engine: nil)
      let pageTools = InspectorPageToolsModel(inspector: inspector, developer: developer)
      pageTools.start()
      try capture(
        InspectorPageToolsView(inspector: inspector, model: pageTools)
          .frame(width: 1040, height: 620)
          .environment(\.colorScheme, scheme).shellLocalization()
          .background(Color(nsColor: .windowBackgroundColor)),
        named: "after-dev-mode-hebrew-\(suffix)", appearance: appearance, root: root)
      pageTools.stop()
      developer.close()

      let domInspector = InspectorModel(target: target, engine: nil)
      domInspector.open()
      try domInspector.receive(InspectorPanelTests.fixtureSelection())
      let dom = ShaarDevToolsModel(target: target, domTransport: DOMFixtureTransport())
      dom.open(inspector: domInspector)
      for _ in 0..<30 where dom.dom.rootID == nil { await Task.yield() }
      XCTAssertTrue(dom.dom.available)
      try capture(
        ShaarDevToolsPanel(model: dom, inspector: domInspector, openChromium: {})
          .frame(width: 1040, height: 620)
          .environment(\.colorScheme, scheme).shellLocalization(),
        named: "after-elements-dom-hebrew-\(suffix)", appearance: appearance, root: root)
      dom.close()
      domInspector.close()
    }
    shell.close()
    inspector.close()
    XCTAssertTrue(NSApp.keyWindow === previous)
  }

  private func capture<V: View>(
    _ view: V, named name: String, appearance: NSAppearance.Name, root: URL
  ) throws {
    let image = try VisualCapture.renderOffscreen(
      view, size: NSSize(width: 1040, height: 620), appearance: appearance,
      to: root.appending(path: "\(name).png"))
    XCTAssertEqual(image.pixelsWide, 1040)
    XCTAssertEqual(image.pixelsHigh, 620)
  }
}
