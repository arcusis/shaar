// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarDevToolsLayoutVisualTests: XCTestCase {
  func testDockModesRenderOffscreenInBothAppearances() async throws {
    guard ProcessInfo.processInfo.environment["SHAAR_DEVTOOLS_LAYOUT_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen layout capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1122")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/")!)
    let inspector = InspectorModel(target: target, engine: nil)
    let defaults = UserDefaults(suiteName: "ShaarDevToolsVisualTests.\(UUID())")!
    let shell = ShaarDevToolsModel(
      target: target,
      transport: ShaarDevToolsFixtureTransport(fixture: [
        .console(
          ShaarConsoleEvent(
            id: UUID(), level: .info, message: "Dashboard ready", source: "app.ts"))
      ]),
      layoutDefaults: defaults)
    shell.open(inspector: inspector)
    shell.section = .console
    for _ in 0..<40 where shell.events.isEmpty { await Task.yield() }
    XCTAssertTrue(shell.streamAvailable && !shell.events.isEmpty)

    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      for dock in [ShaarDevToolsDock.right, .bottom, .left] {
        shell.dock = dock
        let view = InspectorPageLayout(
          model: inspector, shell: shell, openChromium: {}, page: { self.samplePage }
        )
        .frame(width: 1040, height: 680)
        .environment(\.colorScheme, scheme)
        try VisualCapture.renderOffscreen(
          view, size: NSSize(width: 1040, height: 680), appearance: appearance,
          to: root.appending(path: "after-\(dockName(dock))-\(suffix).png"))
      }
      shell.dock = .right
      let narrow = InspectorPageLayout(
        model: inspector, shell: shell, openChromium: {}, page: { self.samplePage }
      )
      .frame(width: 620, height: 680)
      .environment(\.colorScheme, scheme)
      try VisualCapture.renderOffscreen(
        narrow, size: NSSize(width: 620, height: 680), appearance: appearance,
        to: root.appending(path: "after-right-narrow-\(suffix).png"))

      shell.dock = .floating
      let floating = ShaarDevToolsPanel(model: shell, inspector: inspector, openChromium: {})
        .frame(width: 850, height: 620)
        .environment(\.colorScheme, scheme)
      try VisualCapture.renderOffscreen(
        floating, size: NSSize(width: 850, height: 620), appearance: appearance,
        to: root.appending(path: "after-floating-\(suffix).png"))
    }
    shell.close()
    XCTAssertTrue(NSApp.keyWindow === previous)
  }

  private func dockName(_ dock: ShaarDevToolsDock) -> String {
    switch dock {
    case .right: "right"
    case .bottom: "bottom"
    case .left: "left"
    case .floating: "floating"
    }
  }

  private var samplePage: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("localhost:3000/dashboard")
        .font(.system(size: 12, design: .monospaced))
      Divider()
      Text("Dashboard").font(.system(size: 24, weight: .semibold))
      Text("Inspect the local build while you work.")
      Spacer()
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(nsColor: .textBackgroundColor))
  }
}
