// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarDevToolsCSSOverviewVisualTests: XCTestCase {
  func testCSSOverviewRendersOffscreenInBothAppearances() throws {
    guard ProcessInfo.processInfo.environment["SHAAR_DEVTOOLS_CSS_OVERVIEW_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen CSS overview capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1315")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let empty = makeShell()
    let populated = makeShell()
    populated.cssOverview.present(CSSOverviewCapture.sheets)
    populated.cssOverview.choose(.color("#336699"))

    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      try render(
        empty, name: "after-empty-\(suffix)", appearance: appearance, scheme: scheme, root: root)
      try render(
        populated, name: "after-css-overview-\(suffix)", appearance: appearance, scheme: scheme,
        root: root)
    }
    populated.close()
    empty.close()
    XCTAssertTrue(NSApp.keyWindow === previous)
  }

  private func makeShell() -> ShaarDevToolsModel {
    let defaults = UserDefaults(suiteName: "ShaarDevToolsCSSOverviewCapture.\(UUID().uuidString)")!
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/dashboard")!)
    return ShaarDevToolsModel(target: target, layoutDefaults: defaults)
  }

  private func render(
    _ shell: ShaarDevToolsModel, name: String, appearance: NSAppearance.Name, scheme: ColorScheme,
    root: URL
  ) throws {
    let inspector = InspectorModel(target: shell.target, engine: nil)
    if !shell.isOpen { shell.open(inspector: inspector) }
    shell.section = .cssOverview
    let panel = ShaarDevToolsPanel(model: shell, inspector: inspector, openChromium: {})
      .frame(width: 850, height: 620)
      .environment(\.colorScheme, scheme)
    try VisualCapture.renderOffscreen(
      panel, size: NSSize(width: 850, height: 620), appearance: appearance,
      to: root.appending(path: "\(name).png"))
  }
}

private enum CSSOverviewCapture {
  static let sheets = [
    ShaarDevToolsCSSSheet(
      name: "site.css", url: "https://localhost/site.css",
      text: """
        body { color: #336699; background: rgb(255, 255, 255); }
        h1 { font-family: "Iowan Old Style", Georgia, serif; color: #336699; }
        @media (min-width: 40em) {
          .card { font: 700 16px/1.4 "Iowan Old Style"; box-shadow: 0 1px 2px rgba(0, 0, 0, 0.4); }
        }
        """),
    ShaarDevToolsCSSSheet(
      name: "empty.css", url: "https://localhost/empty.css",
      text: "/* unused */ .spacer { margin: 0; }"),
    ShaarDevToolsCSSSheet(
      name: "type.css", url: "https://localhost/type.css",
      text: """
        code { font-family: "Local Sans", monospace; color: red; }
        @media (prefers-reduced-motion: reduce) { code { color: red; } }
        """),
  ]
}
