// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarDevToolsAuditsVisualTests: XCTestCase {
  func testAuditsPanelRendersOffscreenInBothAppearances() throws {
    guard ProcessInfo.processInfo.environment["SHAAR_DEVTOOLS_AUDITS_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen audits capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1312")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let empty = makeShell()
    let populated = makeShell()
    populated.open(inspector: InspectorModel(target: populated.target, engine: nil))
    populated.presentAuditFixture(report: AuditsCapture.report, budget: AuditsCapture.budget)

    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      try render(
        empty, name: "after-empty-\(suffix)", appearance: appearance, scheme: scheme, root: root)
      try render(
        populated, name: "after-audits-\(suffix)", appearance: appearance, scheme: scheme,
        root: root)
    }
    populated.close()
    empty.close()
    XCTAssertTrue(NSApp.keyWindow === previous)
  }

  private func makeShell() -> ShaarDevToolsModel {
    let defaults = UserDefaults(suiteName: "ShaarDevToolsAuditsCapture.\(UUID().uuidString)")!
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
    shell.section = .audits
    let panel = ShaarDevToolsPanel(model: shell, inspector: inspector, openChromium: {})
      .frame(width: 850, height: 620)
      .environment(\.colorScheme, scheme)
    try VisualCapture.renderOffscreen(
      panel, size: NSSize(width: 850, height: 620), appearance: appearance,
      to: root.appending(path: "\(name).png"))
  }
}

private enum AuditsCapture {
  static let report = InspectorAuditModel.Report(
    scope: "page", violations: 2, incomplete: 1,
    findings: [
      InspectorAuditModel.Finding(
        id: "button-name", ruleID: "button-name", impact: "serious",
        title: "Buttons must have discernible text", help: "Add an accessible name",
        helpURL: "https://dequeuniversity.com/rules/axe/4.14/button-name",
        target: "#save", summary: "The button has no accessible name"),
      InspectorAuditModel.Finding(
        id: "color-contrast", ruleID: "color-contrast", impact: "moderate",
        title: "Elements must meet minimum color contrast", help: "Increase contrast",
        helpURL: "https://dequeuniversity.com/rules/axe/4.14/color-contrast",
        target: ".price", summary: "Contrast is too low"),
    ],
    truncated: false)

  static let budget = ShaarRouteBudget(
    route: "/dashboard", lcpMilliseconds: 2_500, inpMilliseconds: 200, cls: 0.1,
    javascriptBytes: 1_000, requestCount: 10
  ).evaluate(
    lcpMilliseconds: 3_000, inpMilliseconds: 100, cls: nil, javascriptBytes: 500, requestCount: 4)
}
