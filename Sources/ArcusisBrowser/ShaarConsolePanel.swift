// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI

struct ShaarConsolePanel: View {
  @Bindable var model: ShaarConsoleModel
  let events: [ShaarDevToolsEvent]
  let droppedCount: Int
  let inspector: InspectorModel?

  private var rows: [ShaarConsoleRow] {
    if events.count <= 500 && model.projection.result == nil { return model.rows(from: events) }
    return model.projection.result ?? []
  }

  var body: some View {
    VStack(spacing: 0) {
      filters
      Divider()
      GeometryReader { geometry in
        HStack(spacing: 0) {
          rowList
            .frame(minWidth: 0, maxWidth: .infinity)
          Divider()
          detail
            .frame(width: min(300, max(180, geometry.size.width * 0.38)))
        }
      }
    }
    .accessibilityIdentifier("shaar.devtools.consolePanel")
    .task { model.scheduleRows(from: events) }
    .onChange(of: events.last) { _, _ in model.scheduleRows(from: events) }
    .onChange(of: model.level) { _, _ in model.scheduleRows(from: events) }
    .onChange(of: model.origin) { _, _ in model.scheduleRows(from: events) }
    .onChange(of: model.search) { _, _ in model.scheduleRows(from: events) }
  }

  private var filters: some View {
    HStack(spacing: 7) {
      ScrollView(.horizontal) {
        HStack(spacing: 7) {
          filterButton("All", level: nil)
          filterButton("Errors", level: .error)
          filterButton("Warnings", level: .warning)
          filterButton("Info", level: .info)
          filterButton("Logs", level: .log)
          Divider().frame(height: 16)
          sourceFilterButton("All sources", origin: nil)
          ForEach(ShaarConsoleEvent.Origin.allCases, id: \.self) { origin in
            sourceFilterButton(origin.rawValue, origin: origin)
          }
        }
      }
      .scrollIndicators(.hidden)
      TextField(ShellL10n.string("Search console"), text: $model.search)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 11))
        .frame(width: 170)
        .accessibilityIdentifier("shaar.devtools.consoleSearch")
    }
    .padding(.horizontal, 12)
    .frame(height: 38)
  }

  private func filterButton(_ title: String, level: ShaarConsoleEvent.Level?) -> some View {
    let selected = model.level == level
    return filterChip(title, selected: selected) { model.level = level }
  }

  private func sourceFilterButton(
    _ title: String, origin: ShaarConsoleEvent.Origin?
  ) -> some View {
    let selected = model.origin == origin
    return filterChip(title, selected: selected) { model.origin = origin }
  }

  private func filterChip(
    _ title: String, selected: Bool, action: @escaping () -> Void
  ) -> some View {
    return Button {
      action()
    } label: {
      Text(ShellL10n.string(title))
        .font(.system(size: 10, weight: selected ? .semibold : .regular))
        .foregroundStyle(selected ? .primary : .secondary)
        .padding(.horizontal, 9)
        .frame(height: 23)
        .background(Color.primary.opacity(selected ? 0.09 : 0.04), in: Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  private var rowList: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        if droppedCount > 0 {
          Text("\(droppedCount) \(ShellL10n.string("older entries dropped"))")
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .accessibilityIdentifier("shaar.devtools.consoleDropped")
        }
        if rows.isEmpty {
          Text(ShellL10n.string("No console messages yet"))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 65)
        }
        ForEach(rows) { row in
          Button {
            model.selectedID = row.id
          } label: {
            HStack(spacing: 9) {
              Image(systemName: symbol(for: row.event.level))
                .font(.system(size: 11))
                .foregroundStyle(color(for: row.event.level))
                .frame(width: 14)
              Text(ShellL10n.string(row.event.origin.rawValue))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .frame(height: 17)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
              Text(row.event.message)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .devToolsDataDirection()
              if row.count > 1 {
                Text("\(row.count)")
                  .font(.system(size: 10, design: .monospaced))
                  .foregroundStyle(.secondary)
                  .padding(.horizontal, 6)
                  .background(Color.primary.opacity(0.07), in: Capsule())
              }
              if let source = row.event.source {
                Text(source.split(separator: "/").last.map(String.init) ?? source)
                  .font(.system(size: 10, design: .monospaced))
                  .foregroundStyle(.tertiary)
                  .lineLimit(1)
              }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(model.selectedID == row.id ? Color.accentColor.opacity(0.10) : .clear)
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("shaar.devtools.consoleEntry")
          Divider()
        }
      }
    }
  }

  @ViewBuilder private var detail: some View {
    if let row = rows.first(where: { $0.id == model.selectedID }) {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text(ShellL10n.string("Console entry"))
              .font(.system(size: 11, weight: .semibold))
            Spacer()
            Button(ShellL10n.string("Copy for agent")) { copyForAgent(row) }
              .buttonStyle(.plain)
              .font(.system(size: 10))
              .help(ShellL10n.string("Copy console entry for agent"))
          }
          Text(row.event.message)
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .devToolsDataDirection()
          Text(ShellL10n.string(row.event.origin.rawValue))
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
          if let source = row.event.source { sourceLink(source, title: source) }
          if row.event.objectID != nil || !row.event.previewProperties.isEmpty {
            objectPreview(row.event)
          }
          if !row.event.stack.isEmpty {
            Text(ShellL10n.string("Stack trace"))
              .font(.system(size: 10, weight: .semibold))
              .foregroundStyle(.secondary)
            ForEach(row.event.stack, id: \.self) { frame in
              sourceLink(frame.source, title: "\(frame.function) · \(frame.source)")
            }
          }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    } else {
      Text(ShellL10n.string("Select a console entry"))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func objectPreview(_ event: ShaarConsoleEvent) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        Task { await model.toggleProperties(for: event, inspector: inspector) }
      } label: {
        Label(
          ShellL10n.string("Object properties"),
          systemImage: model.expanded.contains(event.id) ? "chevron.down" : "chevron.right")
      }
      .buttonStyle(.plain)
      .font(.system(size: 10, weight: .semibold))
      if model.expanded.contains(event.id) {
        ForEach(model.properties[event.id] ?? [], id: \.name) { property in
          HStack(alignment: .firstTextBaseline) {
            Text(property.name).foregroundStyle(.secondary)
            Text(property.value).textSelection(.enabled)
          }
          .font(.system(size: 10, design: .monospaced))
        }
        if let failure = model.propertyFailures[event.id] {
          Text(failure).font(.system(size: 10)).foregroundStyle(.red)
        }
      }
    }
  }

  @ViewBuilder private func sourceLink(_ source: String, title: String) -> some View {
    if let location = InspectorSourceLocation.parse(source) {
      Button {
        let editor =
          InspectorSourceEditor(
            rawValue: UserDefaults.standard.string(forKey: "inspectorSourceEditor") ?? "vscode")
          ?? .vscode
        if let url = location.editorURL(editor) { NSWorkspace.shared.open(url) }
      } label: {
        Text(title).font(.system(size: 10, design: .monospaced)).lineLimit(2)
      }
      .buttonStyle(.link)
      .help(ShellL10n.string("Open source in editor"))
    } else {
      Text(title)
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary)
    }
  }

  private func copyForAgent(_ row: ShaarConsoleRow) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(model.agentCopyText(for: row), forType: .string)
  }

  private func symbol(for level: ShaarConsoleEvent.Level) -> String {
    switch level {
    case .error: "xmark.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .info: "info.circle"
    case .log: "text.bubble"
    }
  }

  private func color(for level: ShaarConsoleEvent.Level) -> Color {
    switch level {
    case .error: .red
    case .warning: .orange
    case .info, .log: .secondary
    }
  }
}

struct ShaarConsoleCommandLine: View {
  @Bindable var model: ShaarConsoleModel
  let inspector: InspectorModel?
  @FocusState private var focused: Bool

  var body: some View {
    HStack(spacing: 8) {
      Text(">")
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .foregroundStyle(.secondary)
      TextField(ShellL10n.string("Evaluate JavaScript in this tab"), text: $model.command)
        .textFieldStyle(.plain)
        .font(.system(size: 11, design: .monospaced))
        .devToolsDataDirection()
        .focused($focused)
        .onSubmit(runCommand)
        .onMoveCommand { direction in
          guard focused else { return }
          if direction == .up { model.command = model.historyCommand(up: true) ?? model.command }
          if direction == .down {
            model.command = model.historyCommand(up: false) ?? model.command
          }
        }
        .disabled(model.busy || inspector == nil)
        .accessibilityIdentifier("shaar.devtools.consoleCommand")
      if model.busy { ProgressView().controlSize(.mini) }
    }
    .padding(.horizontal, 12)
    .frame(height: 34)
  }

  private func runCommand() {
    guard let inspector else { return }
    Task {
      await model.submit { expression in
        let value = try await inspector.evaluate(expression)
        return String(describing: value ?? "undefined")
      }
    }
  }
}
