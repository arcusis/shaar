// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite struct ShaarDevToolsAuditsTests {
  @Test func reportAndBudgetSummaryCounts() {
    let counts = ShaarDevToolsAuditCounts.make(
      report: AuditsFixture.report, budget: AuditsFixture.budget)
    #expect(counts.hasReport)
    #expect(counts.violations == 2)
    #expect(counts.incomplete == 1)
    #expect(counts.truncated == false)
    #expect(counts.hasBudget)
    #expect(counts.passed == 3)
    #expect(counts.over == 1)
    #expect(counts.unavailable == 1)
    let rows = ShaarDevToolsAudits.rows(from: AuditsFixture.report)
    #expect(rows.map(\.impact) == ["serious", "moderate"])
    #expect(rows[0].title == "Buttons must have discernible text")
    #expect(rows[0].target == "#save")

    let empty = ShaarDevToolsAuditCounts.make(report: nil, budget: nil)
    #expect(empty.hasReport == false)
    #expect(empty.hasBudget == false)
    #expect(empty.violations == 0)
    #expect(ShaarDevToolsAudits.rows(from: nil).isEmpty)
  }

  @Test @MainActor func presentedFixtureSuppliesThePanelCounts() {
    let defaults = UserDefaults(suiteName: "ShaarDevToolsAudits.\(UUID().uuidString)")!
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/dashboard")!)
    let shell = ShaarDevToolsModel(target: target, layoutDefaults: defaults)
    shell.open(inspector: InspectorModel(target: target, engine: nil))
    shell.presentAuditFixture(report: AuditsFixture.report, budget: AuditsFixture.budget)
    #expect(shell.auditCounts.violations == 2)
    #expect(shell.auditCounts.over == 1)
    #expect(shell.auditRoute == "/dashboard")
    #expect(shell.auditRows.count == 2)
    shell.close()
  }

  @Test @MainActor func auditsPanelRendersOffscreenForEachState() async throws {
    _ = NSApplication.shared
    let defaults = UserDefaults(suiteName: "ShaarDevToolsAudits.\(UUID().uuidString)")!
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/dashboard")!)
    let inspector = InspectorModel(target: target, engine: nil)
    let shell = ShaarDevToolsModel(target: target, layoutDefaults: defaults)
    shell.open(inspector: inspector)
    shell.section = .audits
    let empty = try VisualCapture.pngOffscreen(
      ShaarDevToolsAuditsPanel(model: shell, inspector: inspector),
      size: NSSize(width: 520, height: 360))
    shell.pageAudit.run()
    let running = try VisualCapture.pngOffscreen(
      ShaarDevToolsAuditsPanel(model: shell, inspector: inspector),
      size: NSSize(width: 520, height: 360))
    for _ in 0..<40 where shell.auditFailure == nil { await Task.yield() }
    #expect(shell.auditFailure != nil)
    shell.pageAudit.setScope(.selected)
    let selected = try VisualCapture.pngOffscreen(
      ShaarDevToolsAuditsPanel(model: shell, inspector: inspector),
      size: NSSize(width: 520, height: 360))
    shell.presentAuditFixture(report: AuditsFixture.varied, budget: AuditsFixture.budget)
    #expect(ShaarDevToolsAudits.impactTitle("critical") == "Critical")
    #expect(ShaarDevToolsAudits.impactTitle("serious") == "Serious")
    #expect(ShaarDevToolsAudits.impactTitle("moderate") == "Moderate")
    #expect(ShaarDevToolsAudits.impactTitle("minor") == "Minor")
    #expect(ShaarDevToolsAudits.impactTitle("custom") == "Unknown")
    #expect(
      ShaarDevToolsAudits.groups(shell.auditRows).map(\.impact) == [
        "critical", "serious", "moderate", "minor", "custom",
      ])
    shell.openAuditFinding("missing")
    let populated = try VisualCapture.pngOffscreen(
      ShaarDevToolsAuditsPanel(model: shell, inspector: inspector),
      size: NSSize(width: 520, height: 420))
    shell.presentAuditFixture(report: AuditsFixture.clear, budget: nil)
    #expect(shell.auditRoute == nil)
    let clear = try VisualCapture.pngOffscreen(
      ShaarDevToolsAuditsPanel(model: shell, inspector: inspector),
      size: NSSize(width: 520, height: 280))
    let panel = try VisualCapture.pngOffscreen(
      ShaarDevToolsPanel(model: shell, inspector: inspector, openChromium: {}),
      size: NSSize(width: 850, height: 620))
    #expect(!empty.isEmpty)
    #expect(!running.isEmpty)
    #expect(!selected.isEmpty)
    #expect(!populated.isEmpty)
    #expect(!clear.isEmpty)
    #expect(!panel.isEmpty)
    shell.close()
  }
}

enum AuditsFixture {
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

  static let varied = InspectorAuditModel.Report(
    scope: "page", violations: 5, incomplete: 2,
    findings: [
      finding("critical-name", "critical", "Critical control has no name", "#save"),
      finding("button-name", "serious", "Buttons must have discernible text", "#save"),
      finding("color-contrast", "moderate", "Elements must meet minimum color contrast", ".price"),
      finding("minor-label", "minor", "Label is unclear", "label"),
      finding("custom-rule", "custom", "Custom rule", ""),
    ],
    truncated: false)

  static let clear = InspectorAuditModel.Report(
    scope: "page", violations: 0, incomplete: 0, findings: [], truncated: true)

  private static func finding(
    _ id: String, _ impact: String, _ title: String, _ target: String
  ) -> InspectorAuditModel.Finding {
    InspectorAuditModel.Finding(
      id: id, ruleID: id, impact: impact, title: title, help: "Fix the control",
      helpURL: "https://dequeuniversity.com/rules/axe/4.14/\(id)", target: target,
      summary: title)
  }
}
