// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarDevToolsIssuesVisualTests: XCTestCase {
  func testIssuesPanelRendersOffscreenInBothAppearances() async throws {
    guard ProcessInfo.processInfo.environment["SHAAR_DEVTOOLS_ISSUES_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen issues capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1311")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let empty = try makeShell(transport: nil)
    let populated = try makeShell(transport: IssuesCaptureTransport())
    populated.open(inspector: inspector(for: populated))
    for _ in 0..<40 where populated.issues.count < 3 { await Task.yield() }
    XCTAssertEqual(populated.issues.count, 3)
    populated.section = .issues

    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      try render(
        empty, name: "after-empty-\(suffix)", appearance: appearance, scheme: scheme, root: root)
      try render(
        populated, name: "after-issues-\(suffix)", appearance: appearance, scheme: scheme,
        root: root)
    }
    populated.close()
    XCTAssertTrue(NSApp.keyWindow === previous)
  }

  private func makeShell(transport: (any ShaarDevToolsEventTransport)?) throws -> ShaarDevToolsModel
  {
    let defaults = UserDefaults(suiteName: "ShaarDevToolsIssuesCapture.\(UUID().uuidString)")!
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/dashboard")!)
    if let transport {
      return ShaarDevToolsModel(target: target, transport: transport, layoutDefaults: defaults)
    }
    return ShaarDevToolsModel(target: target, layoutDefaults: defaults)
  }

  private func inspector(for shell: ShaarDevToolsModel) -> InspectorModel {
    InspectorModel(target: shell.target, engine: nil)
  }

  private func render(
    _ shell: ShaarDevToolsModel, name: String, appearance: NSAppearance.Name, scheme: ColorScheme,
    root: URL
  ) throws {
    let inspector = inspector(for: shell)
    if !shell.isOpen { shell.open(inspector: inspector) }
    shell.section = .issues
    let panel = ShaarDevToolsPanel(model: shell, inspector: inspector, openChromium: {})
      .frame(width: 850, height: 620)
      .environment(\.colorScheme, scheme)
    try VisualCapture.renderOffscreen(
      panel, size: NSSize(width: 850, height: 620), appearance: appearance,
      to: root.appending(path: "\(name).png"))
  }
}

private struct IssuesCaptureTransport: ShaarDevToolsEventTransport {
  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarDevToolsTransportMessage> {
    AsyncStream { continuation in
      continuation.yield(.streamAvailable)
      continuation.yield(
        .event(
          .console(
            ShaarConsoleEvent(
              id: UUID(), level: .error, message: "Dashboard failed", source: "app.ts"))))
      continuation.yield(
        .event(
          .console(
            ShaarConsoleEvent(
              id: UUID(), level: .error, message: "Dashboard failed", source: "app.ts"))))
      continuation.yield(
        .event(
          .console(
            ShaarConsoleEvent(
              id: UUID(), level: .warning, message: "Slow response", source: "app.ts"))))
      continuation.yield(
        .event(
          .network(
            ShaarNetworkEvent(
              id: UUID(), method: "GET", url: "http://localhost:3000/api", status: 500,
              requestID: "req-9"))))
      continuation.finish()
    }
  }
}
