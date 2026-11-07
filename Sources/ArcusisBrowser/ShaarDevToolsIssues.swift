// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SwiftUI

struct ShaarDevToolsIssue: Equatable, Identifiable, Sendable {
  enum Kind: Equatable, Sendable {
    case console(id: UUID, level: ShaarConsoleEvent.Level)
    case network(id: String, status: Int?, failure: String?)
  }

  var kind: Kind
  var title: String
  var detail: String
  var count: Int

  var id: String {
    switch kind {
    case .console(let id, _): "console:\(id.uuidString)"
    case .network(let id, _, _): "network:\(id)"
    }
  }
}

enum ShaarDevToolsIssues {
  static func list(
    console events: [ShaarConsoleEvent], requests: [ShaarNetworkRequest]
  ) -> [ShaarDevToolsIssue] {
    consoleIssues(events) + networkIssues(requests)
  }

  static func countText(_ count: Int) -> String {
    if count > 99 { return "99+" }
    return String(count)
  }

  private static func consoleIssues(_ events: [ShaarConsoleEvent]) -> [ShaarDevToolsIssue] {
    var order: [String] = []
    var grouped: [String: ShaarDevToolsIssue] = [:]
    for event in events where isProblem(event.level) {
      let key = "\(event.level.rawValue)\u{0}\(event.message)"
      if var existing = grouped[key] {
        existing.count += 1
        grouped[key] = existing
      } else {
        order.append(key)
        grouped[key] = ShaarDevToolsIssue(
          kind: .console(id: event.id, level: event.level),
          title: event.message, detail: event.source ?? "", count: 1)
      }
    }
    return order.compactMap { grouped[$0] }
  }

  private static func isProblem(_ level: ShaarConsoleEvent.Level) -> Bool {
    switch level {
    case .warning, .error: true
    case .log, .info: false
    }
  }

  private static func networkIssues(_ requests: [ShaarNetworkRequest]) -> [ShaarDevToolsIssue] {
    requests.filter(\.isError).map { request in
      ShaarDevToolsIssue(
        kind: .network(id: request.id, status: request.status, failure: request.failure),
        title: request.name, detail: networkDetail(request), count: 1)
    }
  }

  private static func networkDetail(_ request: ShaarNetworkRequest) -> String {
    if let failure = request.failure, !failure.isEmpty {
      return "\(request.method) \(failure)"
    }
    if let status = request.status { return "\(request.method) \(status)" }
    return request.method
  }
}

struct ShaarDevToolsIssuesPanel: View {
  @Bindable var model: ShaarDevToolsModel

  var body: some View {
    let issues = model.issues
    Group {
      if issues.isEmpty {
        empty
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(issues) { issue in
              Button {
                model.openIssue(issue)
              } label: {
                ShaarDevToolsIssueRow(issue: issue)
              }
              .buttonStyle(.plain)
              .accessibilityIdentifier("shaar.devtools.issue.\(issue.id)")
            }
          }
        }
      }
    }
    .accessibilityIdentifier("shaar.devtools.issues")
  }

  private var empty: some View {
    VStack(spacing: 8) {
      Image(systemName: "checkmark.circle")
        .font(.system(size: 22, weight: .ultraLight))
      Text(ShellL10n.string("No issues"))
        .font(.system(size: 12, weight: .medium))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .foregroundStyle(.secondary)
  }
}

private struct ShaarDevToolsIssueRow: View {
  let issue: ShaarDevToolsIssue

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: symbol)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(tint)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 1) {
        Text(issue.title)
          .font(.system(size: 12))
          .foregroundStyle(.primary)
          .lineLimit(2)
        if !issue.detail.isEmpty {
          Text(issue.detail)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 0)
      if issue.count > 1 {
        Text(verbatim: ShaarDevToolsIssues.countText(issue.count))
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .contentShape(Rectangle())
  }

  private var symbol: String {
    switch issue.kind {
    case .console(_, let level):
      switch level {
      case .error: "xmark.circle"
      case .warning: "exclamationmark.triangle"
      case .log, .info: "info.circle"
      }
    case .network: "network"
    }
  }

  private var tint: Color {
    switch issue.kind {
    case .console(_, .error), .network: Color.orange
    case .console: Color.secondary
    }
  }
}
