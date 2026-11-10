// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct AgentCopyPanelState: Equatable {
  var scope: AgentCopyScope
  var busy: Bool
  var sizeText: String
  var byteCount: Int?
  var failure: String?
  var notice: String?
  var canCopy: Bool
  var preview: String
  var ruleCount: Int
  var errorCount: Int
  var requestCount: Int
  var consoleRecording: Bool
  var stylesOmitted: Bool
  var source: String
  var screenshotBytes: Int

  static let empty = AgentCopyPanelState(
    scope: .page, busy: false, sizeText: "", byteCount: nil, failure: nil, notice: nil,
    canCopy: false, preview: "", ruleCount: 0, errorCount: 0, requestCount: 0,
    consoleRecording: false, stylesOmitted: false, source: "", screenshotBytes: 0)
}

struct AgentCopyPanel: View {
  let state: AgentCopyPanelState
  let onScope: (AgentCopyScope) -> Void
  let onCopy: () -> Void
  let onHand: () -> Void
  let onRefresh: () -> Void
  let onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      scopeRow
      sizeRow
      summary
      if !state.preview.isEmpty { preview }
      if let failure = state.failure { message(failure, color: .red) }
      if let notice = state.notice { message(notice, color: .secondary) }
      privacy
      actions
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("agent-copy.panel")
    .onExitCommand(perform: onClose)
  }

  private var header: some View {
    HStack {
      Text(ShellL10n.string("Agent packet…"))
        .font(.headline)
      Spacer()
      Button(ShellL10n.string("Close"), action: onClose)
        .accessibilityIdentifier("agent-copy.close")
    }
  }

  private var scopeRow: some View {
    HStack(spacing: 8) {
      scopeButton(.page, title: ShellL10n.string("This page"), identifier: "agent-copy.scope.page")
      scopeButton(
        .element, title: ShellL10n.string("Selected element"),
        identifier: "agent-copy.scope.element")
    }
  }

  private var sizeRow: some View {
    HStack {
      Text(ShellL10n.string("Packet size"))
        .foregroundStyle(.secondary)
      Spacer()
      if state.busy && state.byteCount == nil {
        Text(ShellL10n.string("Building packet…"))
          .foregroundStyle(.secondary)
      } else {
        Text(state.sizeText)
          .accessibilityIdentifier("agent-copy.size")
          .accessibilityValue(byteValue)
      }
    }
    .font(.subheadline)
  }

  private var byteValue: String {
    guard let byteCount = state.byteCount else { return "" }
    return String(byteCount)
  }

  private var summary: some View {
    VStack(alignment: .leading, spacing: 4) {
      labeled(ShellL10n.string("Winning CSS rules"), value: ruleValue)
      labeled(ShellL10n.string("Console errors"), value: consoleValue)
      labeled(ShellL10n.string("Failed requests"), value: String(state.requestCount))
      labeled(ShellL10n.string("Node screenshot"), value: screenshotValue)
      if !state.source.isEmpty {
        labeled(ShellL10n.string("Source location"), value: state.source)
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private var ruleValue: String {
    if state.stylesOmitted { return ShellL10n.string("None recorded.") }
    return String(state.ruleCount)
  }

  private var consoleValue: String {
    if !state.consoleRecording && state.byteCount != nil {
      return ShellL10n.string("No console buffer was running.")
    }
    if state.consoleRecording && state.errorCount == 0 && state.byteCount != nil {
      return ShellL10n.string("None recorded.")
    }
    return String(state.errorCount)
  }

  private var screenshotValue: String {
    if state.screenshotBytes > 0 { return AgentCopySize.text(for: state.screenshotBytes) }
    if state.byteCount != nil { return ShellL10n.string("Screenshot omitted.") }
    return ""
  }

  private var preview: some View {
    Text(state.preview)
      .font(.system(size: 11, design: .monospaced))
      .textSelection(.enabled)
      .lineLimit(12)
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .devToolsDataDirection()
  }

  private var privacy: some View {
    Text(
      ShellL10n.string(
        "Nothing is sent off this Mac. Cookie, Authorization, Set-Cookie, and tokens are removed.")
    )
    .font(.caption)
    .foregroundStyle(.secondary)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var actions: some View {
    HStack(spacing: 8) {
      Button(ShellL10n.string("Copy"), action: onCopy)
        .accessibilityIdentifier("agent-copy.copy")
        .disabled(!state.canCopy)
      Button(ShellL10n.string("Hand to agent"), action: onHand)
        .accessibilityIdentifier("agent-copy.hand")
        .disabled(!state.canCopy)
      Button(ShellL10n.string("Refresh packet"), action: onRefresh)
        .accessibilityIdentifier("agent-copy.refresh")
    }
    .font(.subheadline)
  }

  private func scopeButton(_ scope: AgentCopyScope, title: String, identifier: String) -> some View
  {
    let selected = state.scope == scope
    return Button(title) { onScope(scope) }
      .buttonStyle(.plain)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        selected ? Color.accentColor.opacity(0.16) : Color.clear,
        in: RoundedRectangle(cornerRadius: 8)
      )
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
      .accessibilityIdentifier(identifier)
      .accessibilityAddTraits(selected ? .isSelected : AccessibilityTraits())
  }

  private func labeled(_ title: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
      Spacer(minLength: 8)
      Text(value)
        .multilineTextAlignment(.trailing)
    }
  }

  private func message(_ text: String, color: Color) -> some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(color)
      .fixedSize(horizontal: false, vertical: true)
  }
}
