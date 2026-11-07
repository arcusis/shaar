// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarDevToolsRecorderVisualTests: XCTestCase {
  func testRecorderPanelRendersOffscreenInBothAppearances() throws {
    guard ProcessInfo.processInfo.environment["SHAAR_DEVTOOLS_RECORDER_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen recorder capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1318")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      try render(
        populated: false, name: "before-empty-\(suffix)", appearance: appearance, scheme: scheme,
        root: root)
      try render(
        populated: true, name: "after-recorder-\(suffix)", appearance: appearance, scheme: scheme,
        root: root)
    }
    XCTAssertTrue(NSApp.keyWindow === previous)
  }

  private func render(
    populated: Bool, name: String, appearance: NSAppearance.Name, scheme: ColorScheme, root: URL
  ) throws {
    let defaults = UserDefaults(suiteName: "ShaarDevToolsRecorderCapture.\(UUID().uuidString)")!
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/")!)
    let inspector = InspectorModel(target: target, engine: nil)
    let shell = ShaarDevToolsModel(target: target, layoutDefaults: defaults)
    shell.open(inspector: inspector)
    shell.section = .recorder
    if populated { shell.recorder.apply(Self.steps) }
    let panel = ShaarDevToolsPanel(model: shell, inspector: inspector, openChromium: {})
      .frame(width: 850, height: 620)
      .environment(\.colorScheme, scheme)
    try VisualCapture.renderOffscreen(
      panel, size: NSSize(width: 850, height: 620), appearance: appearance,
      to: root.appending(path: "\(name).png"))
  }

  private static let steps: [[String: Any]] = [
    ["kind": "click", "selector": "#shaar-flow-target", "value": ""],
    ["kind": "change", "selector": "input[name=email]", "value": "ada@example.com"],
  ]
}
