// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct ShaarEventListenersPane: View {
  @Bindable var model: ShaarEventListenersModel

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      toolbar
      Divider()
      content
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .accessibilityIdentifier("shaar.devtools.eventListeners")
  }

  private var toolbar: some View {
    HStack(spacing: 8) {
      Text(ShellL10n.string("Event listeners"))
        .font(.system(size: 11, weight: .semibold))
      Spacer(minLength: 8)
      Toggle(ShellL10n.string("Ancestors"), isOn: $model.includeAncestors)
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .help(ShellL10n.string("Include listeners on ancestors"))
        .accessibilityIdentifier("shaar.devtools.eventListeners.ancestors")
      Button {
        Task { await model.refresh() }
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.plain)
      .help(ShellL10n.string("Refresh event listeners"))
      .accessibilityLabel(ShellL10n.string("Refresh event listeners"))
      .disabled(model.nodeID == nil)
    }
    .padding(.horizontal, 10)
    .frame(height: 32)
  }

  @ViewBuilder private var content: some View {
    if model.nodeID == nil {
      placeholder(ShellL10n.string("Select an element to see its listeners"))
    } else if model.loading && model.listeners.isEmpty {
      ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let failure = model.failure, model.listeners.isEmpty {
      placeholder(failure)
    } else if model.visibleGroups.isEmpty {
      placeholder(ShellL10n.string("No event listeners"))
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(model.visibleGroups) { group in
            groupView(group)
          }
        }
        .padding(.vertical, 4)
      }
      if let failure = model.failure {
        Text(failure)
          .font(.system(size: 10))
          .foregroundStyle(.primary)
          .padding(.horizontal, 10)
          .padding(.bottom, 6)
      }
    }
  }

  private func placeholder(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 11))
      .foregroundStyle(.primary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func groupView(_ group: ShaarEventListenerGroup) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(group.type)
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .devToolsDataDirection()
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 22)
      ForEach(group.rows) { row in listenerRow(row) }
    }
  }

  private func listenerRow(_ row: ShaarEventListener) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(summary(row))
        .font(.system(size: 10, design: .monospaced))
        .lineLimit(1)
        .devToolsDataDirection()
      HStack(spacing: 6) {
        flagButton(
          ShellL10n.string("Passive"), on: row.passive,
          help: ShellL10n.string("Toggle passive"),
          identifier: "shaar.devtools.eventListener.passive"
        ) { Task { await model.togglePassive(row.id) } }
        flagButton(
          ShellL10n.string("Once"), on: row.once,
          help: ShellL10n.string("Toggle once"),
          identifier: "shaar.devtools.eventListener.once"
        ) { Task { await model.toggleOnce(row.id) } }
        Spacer(minLength: 0)
        Button {
          Task { await model.remove(row.id) }
        } label: {
          Image(systemName: "trash")
            .font(.system(size: 10))
            .frame(width: 22, height: 18)
        }
        .buttonStyle(.plain)
        .help(ShellL10n.string("Remove listener"))
        .accessibilityLabel(ShellL10n.string("Remove listener"))
        .accessibilityIdentifier("shaar.devtools.eventListener.remove")
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(rowLabel(row))
    .accessibilityIdentifier("shaar.devtools.eventListener")
  }

  private func flagButton(
    _ title: String, on: Bool, help: String, identifier: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 10, weight: on ? .semibold : .regular))
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(flagFill(on), in: RoundedRectangle(cornerRadius: 3))
    }
    .buttonStyle(.plain)
    .help(help)
    .accessibilityLabel(help)
    .accessibilityAddTraits(on ? .isSelected : [])
    .accessibilityIdentifier(identifier)
  }

  private func flagFill(_ on: Bool) -> Color {
    if on { return Color.accentColor.opacity(0.22) }
    return Color.primary.opacity(0.06)
  }

  private func summary(_ row: ShaarEventListener) -> String {
    var parts = [owner(row), phase(row)]
    if let source = row.source, !source.isEmpty { parts.append(source) }
    return parts.joined(separator: " · ")
  }

  private func rowLabel(_ row: ShaarEventListener) -> String {
    var parts = [row.type, owner(row), phase(row)]
    if let source = row.source, !source.isEmpty { parts.append(source) }
    if row.passive { parts.append(ShellL10n.string("Passive")) }
    if row.once { parts.append(ShellL10n.string("Once")) }
    return parts.joined(separator: ", ")
  }

  private func owner(_ row: ShaarEventListener) -> String {
    ShellL10n.string(row.onAncestor ? "Ancestor" : "This element")
  }

  private func phase(_ row: ShaarEventListener) -> String {
    ShellL10n.string(row.capture ? "Capture" : "Bubble")
  }
}
