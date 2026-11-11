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
