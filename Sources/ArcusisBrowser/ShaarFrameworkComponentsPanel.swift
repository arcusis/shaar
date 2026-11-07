// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import SwiftUI

struct ShaarFrameworkComponentsPanel: View {
  @Bindable var model: ShaarFrameworkComponentsModel
  let openChromium: () -> Void
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast

  var body: some View {
    Group {
      if !model.allowed {
        withheld
      } else if let failure = model.failure, model.rows.isEmpty {
        message(failure, showsChromium: true)
      } else if model.loading && model.rows.isEmpty {
        ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if model.rows.isEmpty {
        message(
          ShellL10n.string("No React, Vue, or Angular component tree on this page"),
          showsChromium: false)
      } else {
        split
      }
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .accessibilityIdentifier("shaar.devtools.componentTree")
  }

  private var split: some View {
    GeometryReader { geometry in
      if geometry.size.width >= 640 {
        HStack(spacing: 0) {
          tree.frame(width: max(240, geometry.size.width * 0.42))
          Divider()
          detail
        }
      } else {
        VStack(spacing: 0) {
          tree.frame(height: max(160, geometry.size.height * 0.52))
          Divider()
          detail
        }
      }
    }
  }

  private var tree: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(model.rows) { row in treeRow(row) }
        }
      }
      .devToolsDataDirection()
    }
    .onMoveCommand { direction in
      switch direction {
      case .up: model.selectAdjacent(forward: false)
      case .down: model.selectAdjacent(forward: true)
      default: break
      }
    }
  }

  private var header: some View {
    HStack(spacing: 7) {
      Image(systemName: "square.stack.3d.up")
        .font(.system(size: 12))
        .foregroundStyle(.primary)
      Text(ShellL10n.string("Component tree"))
        .font(.system(size: 11, weight: .semibold))
      if let framework = model.framework {
        Text(framework.title)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.primary)
          .accessibilityIdentifier("shaar.devtools.components.framework")
      }
      Spacer(minLength: 0)
      Button {
        Task { await model.refresh() }
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.plain)
      .help(ShellL10n.string("Refresh component tree"))
      .accessibilityLabel(ShellL10n.string("Refresh component tree"))
    }
    .padding(.horizontal, 10)
    .frame(height: 36)
  }

  private func treeRow(_ row: ShaarFrameworkRow) -> some View {
    let selected = model.selectedID == row.id
    return Button {
      model.select(row.id)
    } label: {
      HStack(spacing: 6) {
        Text(row.name)
          .font(.system(size: 12, weight: selected ? .semibold : .regular))
          .lineLimit(1)
        if let key = row.key {
          Text(key)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.primary)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }
      .padding(.leading, 10 + CGFloat(row.depth) * 14)
      .padding(.trailing, 10)
      .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
      .background {
        if selected {
          RoundedRectangle(cornerRadius: 5)
            .fill(Color.primary.opacity(colorSchemeContrast == .increased ? 0.16 : 0.08))
            .padding(.horizontal, 4)
        }
      }
    }
    .buttonStyle(.plain)
    .onHover { inside in
      let highlighted = inside ? row.id : model.selectedID
      Task { await model.highlight(highlighted) }
    }
    .help(ShellL10n.string("Component row. Use Up and Down Arrow to change selection."))
    .accessibilityLabel(row.name)
    .accessibilityValue(selected ? ShellL10n.string("Selected") : "")
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityIdentifier("shaar.devtools.component.\(row.id)")
  }

  private var detail: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if let selected = model.selected {
          Text(selected.name)
            .font(.system(size: 13, weight: .semibold))
            .accessibilityIdentifier("shaar.devtools.components.selection")
          fieldSection(
            ShellL10n.string("Props"), selected.props, empty: ShellL10n.string("No props"),
            identifier: "shaar.devtools.components.props", nodeID: selected.id)
          fieldSection(
            ShellL10n.string("State"), selected.state, empty: ShellL10n.string("No state"),
            identifier: "shaar.devtools.components.state")
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
    }
    .devToolsDataDirection()
  }

  private func fieldSection(
    _ title: String, _ fields: [ShaarFrameworkField], empty: String, identifier: String,
    nodeID: String? = nil
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.system(size: 11, weight: .semibold))
        .accessibilityIdentifier(identifier)
      if fields.isEmpty {
        Text(empty)
          .font(.system(size: 11))
          .foregroundStyle(.primary)
      } else {
        ForEach(fields) { field in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(field.name)
              .font(.system(size: 11, weight: .medium))
              .frame(width: 96, alignment: .leading)
              .lineLimit(1)
            if field.accessors.contains("") && nodeID != nil {
              ShaarFrameworkInvokeButton(
                title: "(...)", identifier: "shaar.devtools.components.invoke.\(field.id)"
              ) {
                guard let nodeID else { return }
                Task { await model.invokePropGetter(nodeID: nodeID, name: field.name) }
              }
            } else {
              Text(field.value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            }
            Spacer(minLength: 0)
          }
          if let nodeID {
            ForEach(field.accessors.filter { !$0.isEmpty }, id: \.self) { path in
              if let value = field.invoked[path] {
                Text("\(path): \(value)")
                  .font(.system(size: 11, design: .monospaced))
                  .padding(.leading, 104)
              } else {
                ShaarFrameworkInvokeButton(
                  title: "\(path): (...)",
                  identifier: "shaar.devtools.components.invoke.\(field.id).\(path)"
                ) {
                  Task { await model.invokePropGetter(nodeID: nodeID, name: field.name, path: path) }
                }
                .padding(.leading, 104)
              }
            }
          }
        }
      }
    }
  }

  private var withheld: some View {
    VStack(spacing: 10) {
      Image(systemName: "square.stack.3d.up.slash")
        .font(.system(size: 22, weight: .ultraLight))
        .foregroundStyle(.primary)
      Text(ShellL10n.string("Framework components stay off for this website"))
        .font(.system(size: 12, weight: .medium))
      Text(
        ShellL10n.string(
          "Component tools read only localhost until you turn them on for a site.")
      )
      .font(.system(size: 11))
      .foregroundStyle(.primary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: 360)
      if model.canEnableSite {
        Button(ShellL10n.string("Inspect components here")) {
          model.enableCurrentSite()
          Task { await model.refresh() }
        }
        .controlSize(.small)
        .accessibilityIdentifier("shaar.devtools.components.enable")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
    .accessibilityIdentifier("shaar.devtools.components.withheld")
  }

  private func message(_ text: String, showsChromium: Bool) -> some View {
    VStack(spacing: 10) {
      Image(systemName: "square.stack.3d.up")
        .font(.system(size: 22, weight: .ultraLight))
        .foregroundStyle(.primary)
      Text(text)
        .font(.system(size: 12, weight: .medium))
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
      if showsChromium {
        Button(ShellL10n.string("Open Chromium DevTools"), action: openChromium)
          .help(ShellL10n.string("Open Chromium DevTools with Option-Shift-Command-I"))
          .controlSize(.small)
      } else {
        Button(ShellL10n.string("Refresh component tree")) {
          Task { await model.refresh() }
        }
        .controlSize(.small)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(24)
    .accessibilityIdentifier("shaar.devtools.components.empty")
  }
}

private struct ShaarFrameworkInvokeButton: NSViewRepresentable {
  let title: String
  let identifier: String
  let action: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(action: action) }

  func makeNSView(context: Context) -> NSButton {
    let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.press))
    button.isBordered = false
    button.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    button.toolTip = ShellL10n.string("Invoke getter")
    button.setContentHuggingPriority(.required, for: .horizontal)
    return button
  }

  func updateNSView(_ button: NSButton, context: Context) {
    context.coordinator.action = action
    button.title = title
    button.setAccessibilityIdentifier(identifier)
  }

  final class Coordinator: NSObject {
    var action: () -> Void

    init(action: @escaping () -> Void) { self.action = action }

    @objc func press() { action() }
  }
}
