// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct ShaarConsoleModelTests {
  @Test func levelsSearchAndRepeatsUseOnlyMatchingEntries() {
    let model = ShaarConsoleModel()
    let first = ShaarConsoleEvent(
      id: UUID(), level: .warning, message: "Slow render", source: "/app/Dashboard.tsx:12")
    let second = ShaarConsoleEvent(
      id: UUID(), level: .warning, message: "Slow render", source: "/app/Dashboard.tsx:12")
    let error = ShaarConsoleEvent(id: UUID(), level: .error, message: "Request failed", source: nil)
    let events: [ShaarDevToolsEvent] = [.console(first), .console(second), .console(error)]
    #expect(model.rows(from: events).map(\.count) == [2, 1])
    model.level = .warning
    #expect(model.rows(from: events).map(\.count) == [2])
    model.search = "dashboard"
    #expect(model.rows(from: events).count == 1)
    model.search = "missing"
    #expect(model.rows(from: events).isEmpty)
  }

  @Test func commandHistoryAndEvaluationStayInThePane() async {
    let model = ShaarConsoleModel()
    model.command = " 6 * 7 "
    await model.submit { expression in
      #expect(expression == "6 * 7")
      return "42"
    }
    #expect(model.history == ["6 * 7"])
    #expect(model.historyCommand(up: true) == "6 * 7")
    #expect(model.historyCommand(up: false) == "")
    #expect(model.rows(from: []).map(\.event.message) == ["> 6 * 7", "42"])
    model.clearEntries()
    #expect(model.rows(from: []).isEmpty)
    #expect(model.history == ["6 * 7"])
  }

  @Test func objectPreviewAndAgentCopyAreBounded() {
    let reply: [String: Any] = [
      "result": [
        ["name": "count", "value": ["value": 4]],
        ["name": "state", "value": ["description": "ready"]],
      ]
    ]
    let properties = ShaarConsoleModel.parseProperties(reply)
    #expect(
      properties == [
        ShaarConsoleProperty(name: "count", value: "4"),
        ShaarConsoleProperty(name: "state", value: "ready"),
      ])
    let event = ShaarConsoleEvent(
      id: UUID(), level: .error, message: "Failed", source: "/app/main.ts:8",
      stack: [ShaarConsoleFrame(function: "render", source: "/app/main.ts:8")],
      previewProperties: properties)
    let text = ShaarConsoleModel().agentCopyText(for: .init(event: event, count: 3))
    #expect(text.contains("Repeated 3 times"))
    #expect(text.contains("render (/app/main.ts:8)"))
    #expect(text.contains("count: 4"))
  }
}
