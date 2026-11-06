// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI

struct ShaarNetworkPanel: View {
  @Bindable var model: ShaarNetworkModel
  let events: [ShaarDevToolsEvent]
  @FocusState private var focusedRequest: String?

  private var rows: [ShaarNetworkRequest] { model.visibleRequests(from: events) }
  private var selected: ShaarNetworkRequest? { rows.first { $0.id == model.selectedID } }

  var body: some View {
    VStack(spacing: 0) {
      filters
      Divider()
      GeometryReader { geometry in
        HStack(spacing: 0) {
          requestList
            .frame(minWidth: 0, maxWidth: .infinity)
          Divider()
          detail
            .frame(width: min(340, max(220, geometry.size.width * 0.38)))
        }
      }
    }
    .accessibilityIdentifier("shaar.devtools.networkPanel")
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
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 8)
            .frame(height: 23)
            .background(Color.primary.opacity(selected ? 0.09 : 0.04), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
      Spacer(minLength: 4)
      TextField(ShellL10n.string("Search requests"), text: $model.search)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: 11))
        .frame(width: 150)
        .accessibilityIdentifier("shaar.devtools.networkSearch")
    }
    .padding(.horizontal, 12)
    .frame(height: 38)
  }

  private var requestList: some View {
    GeometryReader { geometry in
      ScrollView([.horizontal, .vertical]) {
        LazyVStack(spacing: 0) {
          tableHeader
          if rows.isEmpty {
            Text(ShellL10n.string(emptyListMessage))
              .font(.system(size: 11))
              .foregroundStyle(.secondary)
              .frame(width: 700, height: 130)
          }
          ForEach(rows) { row in
            Button {
              model.selectedID = row.id
              focusedRequest = row.id
            } label: {
              tableRow(row)
            }
            .buttonStyle(.plain)
            .focusable()
            .focused($focusedRequest, equals: row.id)
            .accessibilityIdentifier("shaar.devtools.networkRequest")
            Divider()
          }
        }
        .frame(width: 700)
        .frame(minHeight: geometry.size.height, alignment: .top)
      }
      .onMoveCommand { direction in
        guard focusedRequest != nil else { return }
        if direction == .down { model.selectAdjacent(in: rows, forward: true) }
        if direction == .up { model.selectAdjacent(in: rows, forward: false) }
        focusedRequest = model.selectedID
      }
    }
  }

  private var emptyListMessage: String {
    if !model.requests(from: events).isEmpty {
      return "No matching requests"
    }
    return "No network requests yet"
  }

  private var tableHeader: some View {
    HStack(spacing: 8) {
      tableLabel("Status", width: 48)
      tableLabel("Method", width: 52)
      tableLabel("Name", width: 200)
      tableLabel("Type", width: 70)
      tableLabel("Size", width: 60)
      tableLabel("Time", width: 56)
      Text(ShellL10n.string("Waterfall"))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .font(.system(size: 10, weight: .medium))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .frame(height: 29)
    .background(Color.primary.opacity(0.035))
  }

  private func tableLabel(_ title: String, width: CGFloat) -> some View {
    Text(ShellL10n.string(title)).frame(width: width, alignment: .leading)
  }

  private func tableRow(_ row: ShaarNetworkRequest) -> some View {
    HStack(spacing: 8) {
      Text(row.failure != nil ? "×" : row.status.map(String.init) ?? "·")
        .foregroundStyle(row.isError ? .red : .primary)
        .frame(width: 48, alignment: .leading)
      Text(row.method).frame(width: 52, alignment: .leading)
      Text(row.name).lineLimit(1).frame(width: 200, alignment: .leading)
      Text(ShellL10n.string(row.resource.rawValue))
        .frame(width: 70, alignment: .leading)
      Text(sizeLabel(row.encodedBytes)).frame(width: 60, alignment: .leading)
      Text(timeLabel(row.duration)).frame(width: 56, alignment: .leading)
      waterfall(row).frame(maxWidth: .infinity)
    }
    .font(.system(size: 10, design: .monospaced))
    .padding(.horizontal, 12)
    .frame(height: 35)
    .background(model.selectedID == row.id ? Color.accentColor.opacity(0.10) : .clear)
    .contentShape(Rectangle())
  }

  private func waterfall(_ row: ShaarNetworkRequest) -> some View {
    GeometryReader { geometry in
      let duration = row.duration ?? 0
      let first = rows.map(\.startedAt).min() ?? row.startedAt
      let last = rows.compactMap(\.completedAt).max() ?? row.startedAt
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
          Text(selected.name)
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
          Spacer(minLength: 4)
          Menu {
            Button(ShellL10n.string("Copy as cURL")) {
              copy(model.curlCommand(for: selected))
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
          ForEach(ShaarNetworkModel.DetailTab.allCases, id: \.self) { tab in
            Button {
              model.detailTab = tab
            } label: {
              Text(ShellL10n.string(tab.rawValue))
                .font(.system(size: 10, weight: model.detailTab == tab ? .semibold : .regular))
                .foregroundStyle(model.detailTab == tab ? .primary : .secondary)
                .padding(.horizontal, 7)
                .frame(height: 26)
                .background {
                  if model.detailTab == tab {
                    RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08))
                  }
                }
            }
            .buttonStyle(.plain)
          }
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        Divider()
        ScrollView {
          detailContent(selected)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
      }
    } else {
      Text(ShellL10n.string("Select a network request"))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder private func detailContent(_ row: ShaarNetworkRequest) -> some View {
    switch model.detailTab {
    case .headers:
      VStack(alignment: .leading, spacing: 12) {
        detailValue("Request URL", row.url)
        detailValue("Request Method", row.method)
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
      if let body = row.responseBody {
        if let tree = model.jsonTree(for: body) {
          ForEach(Array(tree.enumerated()), id: \.offset) { _, node in
            ShaarNetworkJSONTree(node: node)
          }
        } else {
          VStack(alignment: .leading, spacing: 5) {
            Text(String(body.prefix(32_768)))
              .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
            if body.count > 32_768 { emptyDetail("Response preview truncated") }
          }
        }
      } else {
        emptyDetail("No response body is available")
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
          .font(.system(size: 10)).foregroundStyle(.secondary)
      }
      ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
        detailValue(header.name, header.value)
      }
    }
  }

  private func detailValue(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(ShellL10n.string(title))
        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
      Text(value).font(.system(size: 10, design: .monospaced))
        .textSelection(.enabled)
    }
  }

  private func emptyDetail(_ message: String) -> some View {
    Text(ShellL10n.string(message))
      .font(.system(size: 10)).foregroundStyle(.secondary)
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
}

private struct ShaarNetworkJSONTree: View {
  let node: ShaarNetworkJSONNode
  @State private var expanded = true

  var body: some View {
    Group {
      if node.children.isEmpty {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
          Text(node.name).foregroundStyle(.secondary)
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
