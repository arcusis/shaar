// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarDevToolsCoverageVisualTests: XCTestCase {
  func testCoveragePanelRendersOffscreenInBothAppearances() throws {
    guard ProcessInfo.processInfo.environment["SHAAR_DEVTOOLS_COVERAGE_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen coverage capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1316")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      try render(
        populated: false, name: "after-empty-\(suffix)", appearance: appearance, scheme: scheme,
        root: root)
      try render(
        populated: true, name: "after-coverage-\(suffix)", appearance: appearance, scheme: scheme,
        root: root)
    }
    XCTAssertTrue(NSApp.keyWindow === previous)
  }

  private func render(
    populated: Bool, name: String, appearance: NSAppearance.Name, scheme: ColorScheme, root: URL
  ) throws {
    let defaults = UserDefaults(suiteName: "ShaarDevToolsCoverageCapture.\(UUID().uuidString)")!
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/")!)
    let inspector = InspectorModel(target: target, engine: nil)
    let shell = ShaarDevToolsModel(target: target, layoutDefaults: defaults)
    shell.open(inspector: inspector)
    shell.section = .coverage
    if populated { shell.coverage.present(scripts: Self.scripts, sheets: Self.sheets) }
    let panel = ShaarDevToolsPanel(model: shell, inspector: inspector, openChromium: {})
      .frame(width: 850, height: 620)
      .environment(\.colorScheme, scheme)
    try VisualCapture.renderOffscreen(
      panel, size: NSSize(width: 850, height: 620), appearance: appearance,
      to: root.appending(path: "\(name).png"))
    shell.close()
  }

  private static let scripts = [
    ShaarDevToolsCoverageScript(
      url: "http://localhost:3000/app.js",
      ranges: [
        ShaarDevToolsCoverageCountedSpan(start: 0, end: 40, count: 1),
        ShaarDevToolsCoverageCountedSpan(start: 40, end: 100, count: 0),
      ])
  ]

  private static let sheets = [
    ShaarDevToolsCoverageSheet(
      url: "http://localhost:3000/empty.css", totalBytes: 200, usedRanges: [])
  ]
}
