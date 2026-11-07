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

struct ShaarDevToolsAuditsPanel: View {
  @Bindable var model: ShaarDevToolsModel
  let inspector: InspectorModel?

  var body: some View {
    let counts = model.auditCounts
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        controls
        accessibilitySection(counts)
        Divider()
        budget(counts)
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityIdentifier("shaar.devtools.audits")
  }

  private var controls: some View {
    HStack(spacing: 8) {
      Picker(
        ShellL10n.string("Audit scope"),
        selection: Binding(
          get: { model.pageAudit.scope },
          set: { scope in model.pageAudit.setScope(scope) })
      ) {
        Text(ShellL10n.string("Entire page")).tag(InspectorAuditModel.Scope.page)
        Text(ShellL10n.string("Selected element")).tag(InspectorAuditModel.Scope.selected)
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .controlSize(.small)
      .accessibilityIdentifier("shaar.devtools.auditScope")
      Button {
        model.pageAudit.run()
      } label: {
        if model.auditBusy {
          ProgressView().controlSize(.small)
        } else {
          Text(ShellL10n.string("Run audit"))
        }
      }
      .controlSize(.small)
      .disabled(runDisabled)
      .accessibilityIdentifier("shaar.devtools.runAudit")
    }
  }

  private var runDisabled: Bool {
    if model.auditBusy { return true }
    if model.pageAudit.scope == .selected { return inspector?.selection?.locked != true }
    return false
  }

  @ViewBuilder private func accessibilitySection(_ counts: ShaarDevToolsAuditCounts) -> some View {
    Text(ShellL10n.string("Accessibility"))
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(.secondary)
    if let failure = model.auditFailure {
      Text(failure)
        .font(.system(size: 12))
        .foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    }
    if counts.hasReport {
      Text(
        ShellL10n.format(
          "%1$@ violations", arguments: [.string(String(counts.violations))])
      )
      .font(.system(size: 12))
      findings(counts)
    } else if !model.auditBusy {
      Text(ShellL10n.string("Run an audit to check this page."))
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder private func findings(_ counts: ShaarDevToolsAuditCounts) -> some View {
    if counts.violations == 0 {
      Label(ShellL10n.string("No axe-core violations found."), systemImage: "checkmark.circle")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }
    ForEach(ShaarDevToolsAudits.groups(model.auditRows), id: \.impact) { group in
      Text(ShellL10n.string(ShaarDevToolsAudits.impactTitle(group.impact)))
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(impactTint(group.impact))
      ForEach(group.rows) { row in
        Button {
          model.openAuditFinding(row.id)
        } label: {
          ShaarDevToolsAuditFindingRow(row: row)
        }
        .buttonStyle(.plain)
        .disabled(row.target.isEmpty)
        .accessibilityIdentifier("shaar.devtools.audit.\(row.id)")
      }
    }
    if counts.incomplete > 0 {
      Text(
        ShellL10n.format(
          "%1$@ checks need manual review", arguments: [.string(String(counts.incomplete))])
      )
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
    }
    if counts.truncated {
      Text(ShellL10n.string("Audit result list is limited to 300 elements."))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
  }

  private func budget(_ counts: ShaarDevToolsAuditCounts) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(ShellL10n.string("Route budget"))
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
      if counts.hasBudget {
        if let route = model.auditRoute {
          Text(route)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        HStack(spacing: 16) {
          ShaarDevToolsAuditCount(title: "Passed", count: counts.passed, tint: .secondary)
          ShaarDevToolsAuditCount(
            title: "Over", count: counts.over, tint: counts.over > 0 ? .red : .secondary)
          ShaarDevToolsAuditCount(title: "Unavailable", count: counts.unavailable, tint: .secondary)
        }
      } else {
        Text(ShellL10n.string("No route budget for this page"))
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
    }
  }

  private func impactTint(_ impact: String) -> Color {
    switch impact {
    case "critical", "serious": .red
    case "moderate": .orange
    default: .secondary
    }
  }
}

private struct ShaarDevToolsAuditFindingRow: View {
  let row: ShaarDevToolsAuditRow

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(row.title)
        .font(.system(size: 12))
        .foregroundStyle(.primary)
        .lineLimit(2)
        .multilineTextAlignment(.leading)
      if !row.target.isEmpty {
        Text(row.target)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }
}

private struct ShaarDevToolsAuditCount: View {
  let title: String
  let count: Int
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(verbatim: String(count))
        .font(.system(size: 16, weight: .semibold, design: .monospaced))
        .foregroundStyle(tint)
      Text(ShellL10n.string(title))
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
    }
    .frame(minWidth: 72, alignment: .leading)
  }
}
