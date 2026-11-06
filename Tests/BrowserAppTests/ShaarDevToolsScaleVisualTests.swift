// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarDevToolsScaleVisualTests: XCTestCase {
  func testDroppedEntryMarkersRenderOffscreen() throws {
    guard ProcessInfo.processInfo.environment["SHAAR_DEVTOOLS_SCALE_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen scale capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1243")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com")!)
    let events: [ShaarDevToolsEvent] = [
      .console(.init(id: UUID(), level: .info, message: "Latest message", source: nil)),
      .network(.init(id: UUID(), method: "GET", url: "https://example.com/latest", status: 200)),
    ]
    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .light ? "light" : "dark"
      let appearance: NSAppearance.Name = scheme == .light ? .aqua : .darkAqua
      for dropped in [0, 1_000] {
        let stage = dropped == 0 ? "before" : "after"
        let console = ShaarConsolePanel(
          model: ShaarConsoleModel(), events: events, droppedCount: dropped, inspector: nil
        )
        .frame(width: 820, height: 420)
        .background(Color(nsColor: .textBackgroundColor))
        .environment(\.colorScheme, scheme)
        try VisualCapture.renderOffscreen(
          console, size: NSSize(width: 820, height: 420), appearance: appearance,
          to: root.appending(path: "\(stage)-console-\(suffix).png"))
        let network = ShaarNetworkPanel(
          model: ShaarNetworkModel(), rules: ShaarNetworkRulesModel(target: target),
          events: events, droppedCount: dropped, openChromium: {}
        )
        .frame(width: 820, height: 420)
        .background(Color(nsColor: .textBackgroundColor))
        .environment(\.colorScheme, scheme)
        try VisualCapture.renderOffscreen(
          network, size: NSSize(width: 820, height: 420), appearance: appearance,
          to: root.appending(path: "\(stage)-network-\(suffix).png"))
      }
    }
    XCTAssertTrue(NSApp.keyWindow === previous)
  }
}
