// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarDevToolsCommandMenuVisualTests: XCTestCase {
  func testCommandMenuRendersOffscreenInBothAppearances() async throws {
    guard ProcessInfo.processInfo.environment["SHAAR_DEVTOOLS_COMMAND_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen command menu capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1308")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let consoleID = UUID()
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/dashboard")!)
    let inspector = InspectorModel(target: target, engine: nil)
    let defaults = UserDefaults(suiteName: "ShaarDevToolsCommandCapture.\(UUID().uuidString)")!
    let shell = ShaarDevToolsModel(
      target: target, transport: CommandMenuCaptureTransport(consoleID: consoleID),
      layoutDefaults: defaults)
    shell.open(inspector: inspector)
    for _ in 0..<40 where shell.events.count < 2 { await Task.yield() }
    XCTAssertEqual(shell.events.count, 2)
    shell.section = .console
    shell.toggleCommandMenu()
    shell.commandQuery = "dash"

    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      let panel = ShaarDevToolsPanel(model: shell, inspector: inspector, openChromium: {})
        .frame(width: 850, height: 620)
        .environment(\.colorScheme, scheme)
      try VisualCapture.renderOffscreen(
        panel, size: NSSize(width: 850, height: 620), appearance: appearance,
        to: root.appending(path: "after-command-menu-\(suffix).png"))
    }
    shell.close()
    XCTAssertTrue(NSApp.keyWindow === previous)
  }
}

private struct CommandMenuCaptureTransport: ShaarDevToolsEventTransport {
  let consoleID: UUID

  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarDevToolsTransportMessage> {
    AsyncStream { continuation in
      continuation.yield(.streamAvailable)
      continuation.yield(
        .event(
          .console(
            ShaarConsoleEvent(
              id: consoleID, level: .error, message: "Dashboard failed", source: "app.ts"))))
      continuation.yield(
        .event(
          .network(
            ShaarNetworkEvent(
              id: UUID(), method: "GET", url: "http://localhost:3000/dashboard", status: 500))))
      continuation.finish()
    }
  }
}
