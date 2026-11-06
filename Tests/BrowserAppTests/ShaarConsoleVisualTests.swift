// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarConsoleVisualTests: XCTestCase {
  func testConsoleStatesRenderOffscreenInBothAppearances() async throws {
    guard ProcessInfo.processInfo.environment["SHAAR_CONSOLE_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen Console capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1124")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/dashboard")!)
    let first = ShaarConsoleEvent(
      id: UUID(), level: .info, message: "Dashboard ready", source: "/app/Dashboard.tsx:21")
    let warning = ShaarConsoleEvent(
      id: UUID(), level: .warning, message: "Slow render: 148 ms",
      source: "/app/Dashboard.tsx:48")
    let error = ShaarConsoleEvent(
      id: UUID(), level: .error, message: "GET /api/orders failed: 503",
      source: "/app/api/orders.ts:17",
      stack: [ShaarConsoleFrame(function: "loadOrders", source: "/app/api/orders.ts:17")],
      previewProperties: [
        ShaarConsoleProperty(name: "status", value: "503"),
        ShaarConsoleProperty(name: "retryable", value: "true"),
      ])
    let fixture: [ShaarDevToolsEvent] = [
      .console(first), .console(warning), .console(warning), .console(error),
    ]
    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      try capture(
        LegacyConsolePending(), named: "before-console-\(suffix)",
        scheme: scheme, appearance: appearance, root: root)
      let unavailable = ShaarDevToolsModel(target: target)
      unavailable.section = .console
      let inspector = InspectorModel(target: target, engine: nil)
      unavailable.open(inspector: inspector)
      try capture(
        ShaarDevToolsPanel(model: unavailable, inspector: inspector, openChromium: {}),
        named: "after-console-unavailable-\(suffix)", scheme: scheme,
        appearance: appearance, root: root)
      unavailable.close()

      let empty = ShaarDevToolsModel(
        target: target, transport: ShaarDevToolsFixtureTransport(fixture: []))
      empty.section = .console
      empty.open(inspector: inspector)
      for _ in 0..<30 where !empty.streamAvailable { await Task.yield() }
      XCTAssertTrue(empty.streamAvailable)
      try capture(
        ShaarDevToolsPanel(model: empty, inspector: inspector, openChromium: {}),
        named: "after-console-empty-\(suffix)", scheme: scheme,
        appearance: appearance, root: root)
      empty.close()

      let populated = ShaarDevToolsModel(
        target: target, transport: ShaarDevToolsFixtureTransport(fixture: fixture))
      populated.section = .console
      populated.open(inspector: inspector)
      for _ in 0..<30 where populated.events.count < fixture.count { await Task.yield() }
      XCTAssertEqual(populated.events.count, fixture.count)
      try capture(
        ShaarDevToolsPanel(model: populated, inspector: inspector, openChromium: {}),
        named: "after-console-results-\(suffix)", scheme: scheme,
        appearance: appearance, root: root)
      populated.console.selectedID = error.id
      try capture(
        ShaarDevToolsPanel(model: populated, inspector: inspector, openChromium: {}),
        named: "after-console-detail-\(suffix)", scheme: scheme,
        appearance: appearance, root: root)
      populated.close()
    }
    XCTAssertTrue(NSApp.keyWindow === previous)
  }

  private func capture<V: View>(
    _ panel: V, named name: String, scheme: ColorScheme, appearance: NSAppearance.Name,
    root: URL
  ) throws {
    let view = VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        Text("localhost:3000/dashboard")
          .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
        Divider()
        Text("Dashboard").font(.system(size: 24, weight: .semibold))
        Text("Inspect the local build while you work.")
          .font(.system(size: 13)).foregroundStyle(.secondary)
        Spacer()
      }
      .padding(22)
      .frame(height: 180)
      Divider()
      panel.frame(height: 439)
    }
    .frame(width: 1040, height: 620)
    .background(Color(nsColor: .textBackgroundColor))
    .environment(\.colorScheme, scheme)
    let image = try VisualCapture.renderOffscreen(
      view, size: NSSize(width: 1040, height: 620), appearance: appearance,
      to: root.appending(path: "\(name).png"))
    XCTAssertEqual(image.pixelsWide, 1040)
    XCTAssertEqual(image.pixelsHigh, 620)
  }
}

private struct LegacyConsolePending: View {
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 20) {
        Image(systemName: "chevron.left.forwardslash.chevron.right")
        Text("Elements").foregroundStyle(.secondary)
        Text("Console").fontWeight(.semibold)
        Text("Network").foregroundStyle(.secondary)
        Spacer()
        Image(systemName: "ellipsis")
        Image(systemName: "xmark")
      }
      .font(.system(size: 11))
      .padding(.horizontal, 14)
      .frame(height: 36)
      Divider()
      Text("Console events will appear here when the engine stream is available")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      Text("›  Console command line arrives with the Console panel")
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .frame(height: 34)
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }
}
