// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum ShaarNetworkTableLayout {
  static let width: CGFloat = 860
  static let nameWidth: CGFloat = 160
  static let operationWidth: CGFloat = 150
}

struct ShaarNetworkPanel: View {
  @Bindable var model: ShaarNetworkModel
  @Bindable var rules: ShaarNetworkRulesModel
  let events: [ShaarDevToolsEvent]
  let droppedCount: Int
  let openChromium: () -> Void
  @FocusState private var focusedRequest: String?
  @FocusState private var focusedFilter: ShaarNetworkFilter?
  @FocusState private var focusedDetailTab: ShaarNetworkModel.DetailTab?
  @Environment(\.colorSchemeContrast) private var colorSchemeContrast

  private var rows: [ShaarNetworkRequest] {
    if events.count <= 500 { return model.visibleRequests(from: events) }
    return model.projection.result?.rows ?? []
  }
  private var selected: ShaarNetworkRequest? { rows.first { $0.id == model.selectedID } }
  private var detailTabs: [ShaarNetworkModel.DetailTab] {
    selected?.resource == .socket
      ? [.headers, .timing, .messages]
      : ShaarNetworkModel.DetailTab.allCases.filter { $0 != .messages }
  }

  var body: some View {
    VStack(spacing: 0) {
      filters
      conditionsBar
      Divider()
      GeometryReader { geometry in
        HStack(spacing: 0) {
          requestList
            .frame(minWidth: 0, maxWidth: .infinity)
          Divider()
          if rules.showingRules {
            ShaarNetworkRulesEditor(model: rules, openChromium: openChromium)
              .frame(width: min(340, max(220, geometry.size.width * 0.38)))
          } else {
            detail
              .frame(width: min(340, max(220, geometry.size.width * 0.38)))
          }
        }
      }
    }
    .accessibilityIdentifier("shaar.devtools.networkPanel")
    .task { model.scheduleRows(from: events) }
    .onChange(of: events.last) { _, _ in model.scheduleRows(from: events) }
    .onChange(of: model.filter) { _, _ in model.scheduleRows(from: events) }
    .onChange(of: model.statusFilter) { _, _ in model.scheduleRows(from: events) }
    .onChange(of: model.search) { _, _ in model.scheduleRows(from: events) }
    .onChange(of: model.selectedID) { _, id in
      guard let id else { return }
      if selected?.resource != .socket && model.detailTab == .messages {
        model.detailTab = .headers
      }
      Task { await model.loadResponseBody(id: id) }
    }
  }

  private var conditionsBar: some View {
    HStack(spacing: 8) {
      Menu {
        ForEach(ShaarNetworkStatusFilter.allCases, id: \.self) { status in
          Button(ShellL10n.string(status.rawValue)) { model.statusFilter = status }
        }
      } label: {
        Text(ShellL10n.string(model.statusFilter.rawValue))
          .font(.system(size: 11))
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .accessibilityIdentifier("shaar.devtools.networkStatus")
      Menu {
        ForEach(ShaarNetworkThrottle.allCases, id: \.self) { preset in
          Button(ShellL10n.string(preset.rawValue)) {
            Task {
              await ShaarNetworkMenuActions.chooseThrottle(
                preset, conditions: model.conditions)
            }
          }
        }
      } label: {
        Text(ShellL10n.string(model.conditions.throttle.rawValue))
          .font(.system(size: 11))
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .accessibilityIdentifier("shaar.devtools.networkThrottle")
      Toggle(ShellL10n.string("Disable cache"), isOn: cacheDisabled)
        .toggleStyle(.checkbox)
        .font(.system(size: 11))
        .accessibilityIdentifier("shaar.devtools.networkCache")
      Spacer(minLength: 4)
      if let failure = model.conditions.failure {
        Text(failure)
          .font(.system(size: 10))
          .foregroundStyle(.red)
          .lineLimit(1)
          .accessibilityIdentifier("shaar.devtools.networkConditionsFailure")
      }
      Button(ShellL10n.string("Export HAR"), action: exportHAR)
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .accessibilityIdentifier("shaar.devtools.networkHAR")
    }
    .padding(.horizontal, 12)
    .frame(height: 30)
  }

  private var cacheDisabled: Binding<Bool> {
    Binding(
      get: { model.conditions.cacheDisabled },
      set: { disabled in
        Task { await model.conditions.setCacheDisabled(disabled) }
      })
  }

  private var filters: some View {
    HStack(spacing: 6) {
      ForEach(ShaarNetworkFilter.allCases, id: \.self) { filter in
        let selected = model.filter == filter
        Button {
          model.filter = filter
        } label: {
          Text(ShellL10n.string(filter.rawValue))
            .font(.system(size: 10, weight: selected ? .semibold : .regular))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .frame(height: 23)
            .background(Color.primary.opacity(selected ? 0.09 : 0.04), in: Capsule())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focusedFilter, equals: filter)
        .help(ShellL10n.string(filter.accessibilityName))
        .accessibilityHint(
          ShellL10n.string("Use Left and Right Arrow to move through network filters.")
        )
        .accessibilityLabel(ShellL10n.string(filter.accessibilityName))
        .accessibilityIdentifier(filter.accessibilityIdentifier)
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
      Spacer(minLength: 4)
      if rules.activeCount > 0 {
        Text(ShellL10n.format("Rules active · %d", arguments: [.integer(rules.activeCount)]))
          .font(.system(size: 10, weight: .medium))
          .foregroundStyle(.primary)
          .padding(.horizontal, 8)
          .frame(height: 23)
          .background(Color.orange.opacity(0.1), in: Capsule())
          .accessibilityIdentifier("shaar.devtools.networkRulesActive")
      }
      Button {
        rules.showingRules.toggle()
      } label: {
        Text(ShellL10n.format("Rules %d", arguments: [.integer(rules.rules.count)]))
          .font(.system(size: 10, weight: .medium))
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("shaar.devtools.networkRules")
      TextField(ShellL10n.string("Search requests"), text: $model.search)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 11))
        .frame(width: 150)
        .help(ShellL10n.string("Filter requests by URL"))
        .onExitCommand { model.search = "" }
        .accessibilityIdentifier("shaar.devtools.networkSearch")
    }
    .padding(.horizontal, 12)
    .frame(height: 38)
    .onMoveCommand { direction in moveFilter(direction) }
  }

  private func moveFilter(_ direction: MoveCommandDirection) {
    guard let focusedFilter,
      let index = ShaarNetworkFilter.allCases.firstIndex(of: focusedFilter)
    else { return }
    let forward: Bool
    switch direction {
    case .left: forward = false
    case .right: forward = true
    default: return
    }
    guard
      let next = ShaarDevToolsNavigation.adjacentIndex(
        index, count: ShaarNetworkFilter.allCases.count, forward: forward)
    else { return }
    self.focusedFilter = ShaarNetworkFilter.allCases[next]
  }

  private func moveDetailTab(_ direction: MoveCommandDirection) {
    guard let focusedDetailTab,
      let index = detailTabs.firstIndex(of: focusedDetailTab)
    else { return }
    let forward: Bool
    switch direction {
    case .left: forward = false
    case .right: forward = true
    default: return
    }
    guard
      let next = ShaarDevToolsNavigation.adjacentIndex(
        index, count: detailTabs.count, forward: forward)
    else { return }
    self.focusedDetailTab = detailTabs[next]
  }

  private var requestList: some View {
    GeometryReader { geometry in
      let currentRows = rows
      let first = model.projection.result?.firstTime ?? currentRows.map(\.startedAt).min() ?? 0
      let last =
        model.projection.result?.lastTime
        ?? currentRows.map { $0.completedAt ?? $0.startedAt }.max() ?? 0
      ScrollView([.horizontal, .vertical]) {
        LazyVStack(spacing: 0) {
          tableHeader
          if droppedCount > 0 {
            Text("\(droppedCount) \(ShellL10n.string("older entries dropped"))")
              .font(.system(size: 10)).foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(10)
              .accessibilityIdentifier("shaar.devtools.networkDropped")
          }
          if currentRows.isEmpty {
            Text(ShellL10n.string(emptyListMessage))
              .font(.system(size: 11))
              .foregroundStyle(.primary)
              .frame(width: ShaarNetworkTableLayout.width, height: 130)
          }
          ForEach(currentRows) { row in
            Button {
              model.selectedID = row.id
              focusedRequest = row.id
            } label: {
              tableRow(row, first: first, last: last)
            }
            .buttonStyle(.plain)
            .focusable()
            .focused($focusedRequest, equals: row.id)
            .accessibilityLabel(requestLabel(row))
            .help(ShellL10n.string("Network request. Use Up and Down Arrow to change selection."))
            .accessibilityAddTraits(model.selectedID == row.id ? .isSelected : [])
            .accessibilityIdentifier("shaar.devtools.networkRequest")
            .contextMenu {
              Button(ShellL10n.string("Create rule from request")) {
                rules.create(from: row)
              }
              .disabled(!rules.available)
            }
            Divider()
          }
        }
        .frame(width: ShaarNetworkTableLayout.width)
        .frame(minHeight: geometry.size.height, alignment: .top)
        .devToolsDataDirection()
      }
      .onMoveCommand { direction in
        guard focusedRequest != nil else { return }
        if direction == .down {
          model.selectAdjacent(in: currentRows, forward: true, from: focusedRequest)
        }
        if direction == .up {
          model.selectAdjacent(in: currentRows, forward: false, from: focusedRequest)
        }
        focusedRequest = model.selectedID
      }
    }
  }

  private func requestLabel(_ row: ShaarNetworkRequest) -> String {
    let status = row.status.map(String.init) ?? ShellL10n.string("Pending")
    let failure = row.failure.map { ", \(ShellL10n.string("Failed")): \($0)" } ?? ""
    return "\(row.method), \(row.name), \(status), \(row.url)\(operationLabel(row))\(failure)"
  }

  private func operationLabel(_ row: ShaarNetworkRequest) -> String {
    guard let operation = row.apiOperation else { return "" }
    let marker = operation.hasErrors ? ", \(ShellL10n.string("Response has errors"))" : ""
    return ", \(operation.columnText)\(marker)"
  }

  private var emptyListMessage: String {
    if (model.projection.result?.totalCount ?? model.requests(from: events).count) > 0 {
      return "No matching requests"
    }
    return "No network requests yet"
  }

  private var tableHeader: some View {
    HStack(spacing: 8) {
      tableLabel("Status", width: 48)
      tableLabel("Method", width: 52)
      tableLabel("Name", width: ShaarNetworkTableLayout.nameWidth)
      tableLabel("Operation", width: ShaarNetworkTableLayout.operationWidth)
      tableLabel("Type", width: 70)
      tableLabel("Size", width: 60)
      tableLabel("Time", width: 56)
      Text(ShellL10n.string("Waterfall"))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .font(.system(size: 10, weight: .medium))
    .foregroundStyle(.primary)
    .padding(.horizontal, 12)
    .frame(height: 29)
    .background(Color.primary.opacity(0.035))
  }

  private func tableLabel(_ title: String, width: CGFloat) -> some View {
    Text(ShellL10n.string(title)).frame(width: width, alignment: .leading)
  }

  private func tableRow(
    _ row: ShaarNetworkRequest, first: TimeInterval, last: TimeInterval
  ) -> some View {
    HStack(spacing: 8) {
      Text(row.failure != nil ? "×" : row.status.map(String.init) ?? "·")
        .foregroundStyle(.primary)
        .frame(width: 48, alignment: .leading)
      Text(row.method).frame(width: 52, alignment: .leading)
      Text(row.name).lineLimit(1).frame(
        width: ShaarNetworkTableLayout.nameWidth, alignment: .leading)
      operationCell(row)
      Text(ShellL10n.string(row.resource.rawValue))
        .frame(width: 70, alignment: .leading)
      Text(sizeLabel(row.encodedBytes)).frame(width: 60, alignment: .leading)
      Text(timeLabel(row.duration)).frame(width: 56, alignment: .leading)
      waterfall(row, first: first, last: last).frame(maxWidth: .infinity)
    }
    .font(.system(size: 10, design: .monospaced))
    .padding(.horizontal, 12)
    .frame(height: 35)
    .background(
      model.selectedID == row.id
        ? Color.accentColor.opacity(colorSchemeContrast == .increased ? 0.22 : 0.10)
        : .clear
    )
    .overlay {
      if focusedRequest == row.id {
        RoundedRectangle(cornerRadius: 3)
          .strokeBorder(
            Color.primary, lineWidth: colorSchemeContrast == .increased ? 2 : 1)
      }
    }
    .contentShape(Rectangle())
  }

  private func operationCell(_ row: ShaarNetworkRequest) -> some View {
    let failed = row.apiOperation?.hasErrors == true
    return Text(row.apiOperation?.columnText ?? "")
      .lineLimit(1)
      .foregroundStyle(failed ? Color.red : Color.primary)
      .frame(width: ShaarNetworkTableLayout.operationWidth, alignment: .leading)
      .accessibilityIdentifier("shaar.devtools.networkOperation")
      .accessibilityValue(failed ? ShellL10n.string("Response has errors") : "")
  }

  private func waterfall(
    _ row: ShaarNetworkRequest, first: TimeInterval, last: TimeInterval
  ) -> some View {
    GeometryReader { geometry in
      let duration = row.duration ?? 0
      let span = max(0.001, last - first)
      let start = max(0, row.startedAt - first)
      Capsule()
        .fill(row.isError ? Color.red.opacity(0.65) : Color.accentColor.opacity(0.65))
        .frame(width: max(3, geometry.size.width * duration / span), height: 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .offset(x: geometry.size.width * start / span)
    }
  }

  @ViewBuilder private var detail: some View {
    if let selected {
      VStack(spacing: 0) {
        HStack(spacing: 8) {
          VStack(alignment: .leading, spacing: 2) {
            Text(selected.name)
              .font(.system(size: 11, weight: .semibold))
              .lineLimit(1)
            if let operation = selected.apiOperation {
              Text(operation.columnText)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
                .foregroundStyle(operation.hasErrors ? Color.red : Color.secondary)
                .accessibilityIdentifier("shaar.devtools.networkOperationDetail")
                .accessibilityValue(
                  operation.hasErrors ? ShellL10n.string("Response has errors") : "")
            }
          }
          .devToolsDataDirection()
          Spacer(minLength: 4)
          Button {
            rules.create(from: selected)
          } label: {
            Image(systemName: "plus.square.on.square")
          }
          .buttonStyle(.plain)
          .disabled(!rules.available)
          .help(ShellL10n.string("Create rule from request"))
          .accessibilityLabel(ShellL10n.string("Create rule from request"))
          Menu {
            Button(ShellL10n.string("Copy as cURL")) {
              ShaarNetworkMenuActions.copyCurl(selected, model: model)
            }
            Button(ShellL10n.string("Copy as fetch")) {
              copy(model.fetchCommand(for: selected))
            }
            Button(ShellL10n.string("Copy for agent")) {
              copy(model.agentCopyText(for: selected))
            }
          } label: {
            Image(systemName: "square.on.square")
          }
          .menuStyle(.borderlessButton)
          .frame(width: 22)
          .help(ShellL10n.string("Copy request"))
          .accessibilityLabel(ShellL10n.string("Copy request"))
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        Divider()
        HStack(spacing: 2) {
          ForEach(detailTabs, id: \.self) { tab in
            Button {
              model.detailTab = tab
            } label: {
              Text(ShellL10n.string(tab.rawValue))
                .font(.system(size: 10, weight: model.detailTab == tab ? .semibold : .regular))
                .foregroundStyle(.primary)
                .padding(.horizontal, 7)
                .frame(height: 26)
                .background {
                  if model.detailTab == tab {
                    RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08))
                  }
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(
              tab == .messages
                ? "shaar.devtools.networkMessagesTab" : "shaar.devtools.networkDetailTab"
            )
            .focusable()
            .focused($focusedDetailTab, equals: tab)
            .help(ShellL10n.string("Use Left and Right Arrow to move through request details."))
            .accessibilityValue(
              model.detailTab == tab ? ShellL10n.string("Selected") : ""
            )
            .accessibilityAddTraits(model.detailTab == tab ? .isSelected : [])
          }
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .onMoveCommand { direction in moveDetailTab(direction) }
        Divider()
        ScrollView {
          detailContent(selected)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .devToolsDataDirection()
        }
      }
    } else {
      Text(ShellL10n.string("Select a network request"))
        .font(.system(size: 11))
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder private func detailContent(_ row: ShaarNetworkRequest) -> some View {
    switch model.detailTab {
    case .headers:
      VStack(alignment: .leading, spacing: 12) {
        detailValue("Request URL", row.url)
        detailValue("Request Method", row.method)
        if let operation = row.apiOperation {
          detailValue("Operation", operation.columnText)
          if operation.hasErrors {
            Text(ShellL10n.string("Response has errors"))
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(Color.red)
              .accessibilityIdentifier("shaar.devtools.networkOperationError")
          }
        }
        if let status = row.status { detailValue("Status", String(status)) }
        headerSection("Request headers", row.requestHeaders)
        headerSection("Response headers", row.responseHeaders)
      }
    case .payload:
      VStack(alignment: .leading, spacing: 10) {
        if !row.queryItems.isEmpty {
          Text(ShellL10n.string("Query parameters"))
            .font(.system(size: 10, weight: .semibold))
          ForEach(Array(row.queryItems.enumerated()), id: \.offset) { _, item in
            detailValue(item.name, item.value ?? "")
          }
        }
        if let payload = row.payload {
          detailValue("Request body", payload)
        } else if row.queryItems.isEmpty {
          emptyDetail("No request payload is available")
        }
      }
    case .response:
      if row.responseIsBinary {
        emptyDetail("Binary response")
      } else if let body = row.responseBody, !body.isEmpty {
        VStack(alignment: .leading, spacing: 5) {
          Text(String(body.prefix(32_768)))
            .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
          if body.count > 32_768 { emptyDetail("Response preview truncated") }
        }
      } else {
        emptyDetail("No response body is available")
      }
    case .messages:
      if row.frames.isEmpty {
        emptyDetail("No WebSocket messages yet")
      } else {
        LazyVStack(alignment: .leading, spacing: 8) {
          ForEach(Array(row.frames.enumerated()), id: \.offset) { _, frame in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(frame.direction == .sent ? "↑" : "↓")
              Text("\(Int(max(0, frame.time - row.startedAt) * 1_000)) ms")
                .foregroundStyle(.secondary)
              Text(frame.display).textSelection(.enabled)
            }
            .font(.system(size: 10, design: .monospaced))
          }
        }
        .accessibilityIdentifier("shaar.devtools.networkMessages")
      }
    case .preview:
      if let data = row.previewData, let image = NSImage(data: data) {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(maxWidth: 240, maxHeight: 160, alignment: .leading)
          .accessibilityIdentifier("shaar.devtools.networkPreviewImage")
      } else if let body = row.responseBody, !row.responseIsBinary,
        let tree = model.jsonTree(for: body)
      {
        ForEach(Array(tree.enumerated()), id: \.offset) { _, node in
          ShaarNetworkJSONTree(node: node)
        }
      } else {
        emptyDetail("No preview is available")
      }
    case .timing:
      VStack(alignment: .leading, spacing: 10) {
        detailValue("Started", String(format: "%.0f ms", row.startedAt * 1_000))
        if let duration = row.duration {
          detailValue("Duration", timeLabel(duration))
          if let respondedAt = row.respondedAt {
            timingPhase(
              "Waiting for response", seconds: respondedAt - row.startedAt,
              total: duration, color: .orange)
            timingPhase(
              "Download", seconds: (row.completedAt ?? respondedAt) - respondedAt,
              total: duration, color: .blue)
          } else {
            timingPhase("Total", seconds: duration, total: duration, color: .accentColor)
          }
        } else {
          emptyDetail("Request is still in progress")
        }
        if let failure = row.failure { detailValue("Failure", failure) }
      }
    }
  }

  private func timingPhase(
    _ title: String, seconds: TimeInterval, total: TimeInterval, color: Color
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack {
        Text(ShellL10n.string(title))
        Spacer()
        Text(timeLabel(seconds))
      }
      .font(.system(size: 10, design: .monospaced))
      GeometryReader { geometry in
        Capsule().fill(color.opacity(0.75))
          .frame(
            width: max(3, geometry.size.width * max(0, seconds) / max(0.001, total)),
            height: 7)
      }
      .frame(height: 7)
    }
  }

  private func headerSection(_ title: String, _ headers: [ShaarNetworkHeader]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(ShellL10n.string(title)).font(.system(size: 10, weight: .semibold))
      if headers.isEmpty {
        Text(ShellL10n.string("No headers are available"))
          .font(.system(size: 10)).foregroundStyle(.primary)
      }
      ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
        detailValue(header.name, ShaarNetworkHeaderRedaction.value(header))
      }
    }
  }

  private func detailValue(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(ShellL10n.string(title))
        .font(.system(size: 10, weight: .medium)).foregroundStyle(.primary)
      Text(value).font(.system(size: 10, design: .monospaced))
        .textSelection(.enabled)
        .devToolsDataDirection()
    }
  }

  private func emptyDetail(_ message: String) -> some View {
    Text(ShellL10n.string(message))
      .font(.system(size: 10)).foregroundStyle(.primary)
  }

  private func sizeLabel(_ bytes: Int?) -> String {
    guard let bytes else { return "—" }
    if bytes < 1_024 { return "\(bytes) B" }
    return String(format: "%.1f KB", Double(bytes) / 1_024)
  }

  private func timeLabel(_ seconds: TimeInterval?) -> String {
    guard let seconds else { return "—" }
    return "\(Int((seconds * 1_000).rounded())) ms"
  }

  private func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }

  private func exportHAR() {
    let requests = model.exportRequests(from: events)
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "shaar-network.har"
    panel.allowedContentTypes = [.json]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    try? ShaarNetworkHAR.write(requests, to: url)
  }
}

enum ShaarNetworkMenuActions {
  @MainActor static func chooseThrottle(
    _ preset: ShaarNetworkThrottle, conditions: ShaarNetworkConditionsModel
  ) async {
    await conditions.select(preset)
  }

  @MainActor static func copyCurl(
    _ row: ShaarNetworkRequest, model: ShaarNetworkModel, to pasteboard: NSPasteboard = .general
  ) {
    copy(model.curlCommand(for: row), to: pasteboard)
  }

  static func copy(_ value: String, to pasteboard: NSPasteboard) {
    guard !value.isEmpty else { return }
    pasteboard.clearContents()
    pasteboard.setString(value, forType: .string)
  }
}

extension ShaarNetworkFilter {
  fileprivate var accessibilityName: String {
    switch self {
    case .all: "All requests"
    case .fetch: "Fetch and XHR"
    case .script: "JavaScript"
    case .style: "Stylesheets"
    case .image: "Images"
    case .document: "Documents"
    case .socket: "WebSockets"
    case .errors: "Errors"
    case .api: "API requests"
    }
  }

  fileprivate var accessibilityIdentifier: String {
    if self == .api { return "shaar.devtools.networkAPI" }
    return "shaar.devtools.networkFilter"
  }
}

private struct ShaarNetworkJSONTree: View {
  let node: ShaarNetworkJSONNode
  @State private var expanded = true

  var body: some View {
    Group {
      if node.children.isEmpty {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
          Text(node.name).foregroundStyle(.primary)
          Text(node.value ?? "").textSelection(.enabled)
        }
      } else {
        DisclosureGroup(isExpanded: $expanded) {
          VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
              ShaarNetworkJSONTree(node: child)
            }
          }
        } label: {
          Text(node.name)
        }
      }
    }
    .font(.system(size: 10, design: .monospaced))
  }
}
