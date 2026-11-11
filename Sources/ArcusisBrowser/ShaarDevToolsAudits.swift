// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct ShaarDevToolsAuditCounts: Equatable, Sendable {
  var hasReport: Bool
  var violations: Int
  var incomplete: Int
  var truncated: Bool
  var hasBudget: Bool
  var passed: Int
  var over: Int
  var unavailable: Int

  static func make(
    report: InspectorAuditModel.Report?, budget: ShaarPerformanceBudgetResult?
  ) -> ShaarDevToolsAuditCounts {
    ShaarDevToolsAuditCounts(
      hasReport: report != nil,
      violations: report?.violations ?? 0,
      incomplete: report?.incomplete ?? 0,
      truncated: report?.truncated ?? false,
      hasBudget: budget != nil,
      passed: budget?.passed ?? 0,
      over: budget?.failed ?? 0,
      unavailable: budget?.unavailable ?? 0)
  }
}

struct ShaarDevToolsAuditRow: Equatable, Identifiable, Sendable {
  var id: String
  var impact: String
  var title: String
  var target: String
}

enum ShaarDevToolsAudits {
  static let impactOrder = ["critical", "serious", "moderate", "minor", "unknown"]

  static func rows(from report: InspectorAuditModel.Report?) -> [ShaarDevToolsAuditRow] {
    let findings = report?.findings ?? []
    let ordered = impactOrder.flatMap { impact in
      findings.filter { $0.impact == impact }.map(row)
    }
    let remaining = findings.filter { !impactOrder.contains($0.impact) }.map(row)
    return ordered + remaining
  }

  static func groups(
    _ rows: [ShaarDevToolsAuditRow]
  ) -> [(impact: String, rows: [ShaarDevToolsAuditRow])] {
    var order: [String] = []
    for row in rows where !order.contains(row.impact) {
      order.append(row.impact)
    }
    return order.map { impact in
      (impact, rows.filter { $0.impact == impact })
    }
  }

  static func impactTitle(_ impact: String) -> String {
    switch impact {
    case "critical": "Critical"
    case "serious": "Serious"
    case "moderate": "Moderate"
    case "minor": "Minor"
    default: "Unknown"
    }
  }

  private static func row(_ finding: InspectorAuditModel.Finding) -> ShaarDevToolsAuditRow {
    ShaarDevToolsAuditRow(
      id: finding.id, impact: finding.impact, title: finding.title, target: finding.target)
  }
}
