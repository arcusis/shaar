// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct InspectorAuditView: View {
  static let impactGroupHeadingTraits: AccessibilityTraits = .isHeader

  @Bindable var model: InspectorAuditModel
  let inspector: InspectorModel

  private let impacts = ["critical", "serious", "moderate", "minor", "unknown"]

  var body: some View {
    InspectorSection(InspectorDetailsL10n.string("Accessibility audit")) {
      VStack(alignment: .leading, spacing: 8) {
        scopePicker
        runControls
        failureText
        reportContent
        emptyText
      }
    }
    .onChange(of: inspector.selection?.id) { model.selectionChanged() }
  }

  private var scopePicker: some View {
    Picker(
      InspectorDetailsL10n.string("Audit scope"),
      selection: Binding(
        get: { model.scope }, set: { value in model.setScope(value) })
    ) {
      Text(InspectorDetailsL10n.string("Entire page")).tag(InspectorAuditModel.Scope.page)
      Text(InspectorDetailsL10n.string("Selected element")).tag(InspectorAuditModel.Scope.selected)
    }
    .labelsHidden()
    .pickerStyle(.segmented)
    .controlSize(.small)
  }

  private var runControls: some View {
    HStack(spacing: 6) {
      Button(action: model.run) {
        if model.busy {
          ProgressView(InspectorDetailsL10n.string("Auditing…")).controlSize(.small)
        } else {
          Label(InspectorDetailsL10n.string("Run audit"), systemImage: "checkmark.shield")
        }
      }
      .disabled(model.busy || (model.scope == .selected && inspector.selection?.locked != true))
      .help(
        model.scope == .selected && inspector.selection?.locked != true
          ? InspectorDetailsL10n.string("Lock an element before auditing this selection.")
          : InspectorDetailsL10n.string("Run audit"))
      if let report = model.report {
        Text(
          InspectorDetailsL10n.format(
            "%1$@ violations · %2$@ elements",
            arguments: [
              .string(String(report.violations)), .string(String(report.findings.count)),
            ])
        )
        .font(.system(size: 10)).foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder private var failureText: some View {
    if let failure = model.failure {
      Label(InspectorDetailsL10n.string(failure), systemImage: "exclamationmark.triangle")
        .font(.system(size: 10)).foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder private var reportContent: some View {
    if let report = model.report {
      ForEach(impacts, id: \.self) { impact in
        let findings = report.findings.filter { $0.impact == impact }
        if !findings.isEmpty {
          InspectorAuditImpactGroup(impact: impact, findings: findings, select: model.select)
        }
      }
      if report.incomplete > 0 {
        Text(
          InspectorDetailsL10n.format(
            "%1$@ checks need manual review", arguments: [.string(String(report.incomplete))])
        )
        .font(.system(size: 10)).foregroundStyle(.secondary)
      }
      if report.truncated {
        Text(InspectorDetailsL10n.string("Audit result list is limited to 300 elements."))
          .font(.system(size: 10)).foregroundStyle(.secondary)
      }
      if report.violations == 0 {
        Label(
          InspectorDetailsL10n.string("No axe-core violations found."),
          systemImage: "checkmark.circle"
        )
        .font(.system(size: 11)).foregroundStyle(.green)
      }
    }
  }

  @ViewBuilder private var emptyText: some View {
    if model.report == nil, model.failure == nil, !model.busy {
      Text(InspectorDetailsL10n.string("Run an audit to find accessibility issues on this page."))
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct InspectorAuditImpactGroup: View {
  let impact: String
  let findings: [InspectorAuditModel.Finding]
  let select: (InspectorAuditModel.Finding) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(InspectorDetailsL10n.string(impact.capitalized))
        .font(.system(size: 10, weight: .semibold)).foregroundStyle(impactColor)
        .accessibilityAddTraits(InspectorAuditView.impactGroupHeadingTraits)
      ForEach(findings) { finding in
        Button {
          select(finding)
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text(finding.title).font(.system(size: 11, weight: .medium))
              .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            Text(finding.target.isEmpty ? finding.ruleID : finding.target)
              .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
              .lineLimit(2).truncationMode(.middle)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(finding.target.isEmpty)
        .help(finding.help)
      }
    }
    .padding(.top, 3)
  }

  private var impactColor: Color {
    switch impact {
    case "critical", "serious": .red
    case "moderate": .orange
    default: .secondary
    }
  }
}
