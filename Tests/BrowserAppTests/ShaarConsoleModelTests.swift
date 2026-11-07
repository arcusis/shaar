// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct ShaarConsoleModelTests {
  @Test func fiftyThousandEntryFilterProjectsOffMainActor() async {
    let events: [ShaarDevToolsEvent] = (0..<50_000).map { index in
      .console(
        .init(
          id: UUID(), level: index.isMultiple(of: 2) ? .error : .log,
          message: "entry \(index)", source: nil))
    }
    let model = ShaarConsoleModel()
    model.scheduleRows(from: events)
    model.level = .error
    model.scheduleRows(from: events)
    let start = ContinuousClock.now
    for _ in 0..<500 where model.projection.result?.count != 25_000 {
      try? await Task.sleep(for: .milliseconds(10))
    }
    let elapsed = start.duration(to: .now)
    print("Console 50,000-entry projection: \(elapsed)")
    #expect(model.projection.result?.count == 25_000)
    #expect(elapsed < .seconds(5))
  }

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
      return ShaarConsoleEvaluation(message: "42", objectID: nil, previewProperties: [])
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

  @Test func unifiedSourcesFilterAndCopyKeepOrigin() {
    let model = ShaarConsoleModel()
    let browser = ShaarConsoleEvent(id: UUID(), level: .error, message: "Failed", source: nil)
    let server = ShaarConsoleEvent(
      id: UUID(), level: .error, message: "Failed", source: nil, origin: .server)
    let spotlight = ShaarConsoleEvent(
      id: UUID(), level: .warning, message: "Slow query", source: nil, origin: .spotlight)
    let events: [ShaarDevToolsEvent] = [.console(browser), .console(server), .console(spotlight)]
    #expect(model.rows(from: events).map(\.count) == [1, 1, 1])
    model.origin = .server
    #expect(model.rows(from: events).map(\.event.id) == [server.id])
    #expect(model.agentCopyText(for: .init(event: server, count: 1)).contains("Server"))
    model.origin = .spotlight
    model.search = "spotlight"
    #expect(model.rows(from: events).map(\.event.id) == [spotlight.id])
  }

  @Test func unifiedRowsFollowArrivalTimeAcrossSources() {
    let browser = ShaarConsoleEvent(
      id: UUID(), level: .log, message: "Browser", source: nil,
      timestamp: Date(timeIntervalSince1970: 2))
    let server = ShaarConsoleEvent(
      id: UUID(), level: .log, message: "Server", source: nil, origin: .server,
      timestamp: Date(timeIntervalSince1970: 1))
    let rows = ShaarConsoleModel().rows(from: [.console(browser), .console(server)])
    #expect(rows.map(\.event.message) == ["Server", "Browser"])
  }

  @Test func regularExpressionFiltersMessagesAndRejectsInvalidPatterns() {
    let model = ShaarConsoleModel()
    let events: [ShaarDevToolsEvent] = [
      .console(.init(id: UUID(), level: .error, message: "shaar19-live-console", source: nil)),
      .console(.init(id: UUID(), level: .log, message: "ready", source: "/app/main.ts")),
    ]
    model.searchUsesRegex = true
    model.search = "shaar19-live-.*"
    #expect(model.rows(from: events).map(\.event.message) == ["shaar19-live-console"])
    model.search = "MAIN"
    #expect(model.rows(from: events).isEmpty)
    model.search = "("
    #expect(model.regexIsInvalid)
    #expect(model.rows(from: events).isEmpty)
    model.searchUsesRegex = false
    model.search = "MAIN"
    #expect(!model.regexIsInvalid)
    #expect(model.rows(from: events).map(\.event.message) == ["ready"])
  }

  @Test func evaluationKeepsObjectHandlesAndReportsExceptions() throws {
    let reply: [String: Any] = [
      "result": [
        "type": "object",
        "description": "Object",
        "objectId": "obj-7",
        "preview": [
          "properties": [
            ["name": "probe", "value": "1124", "type": "number"],
            ["name": "ok", "type": "boolean"],
          ]
        ],
      ]
    ]
    let evaluation = try ShaarConsoleModel.evaluation(from: reply)
    #expect(evaluation.message == "Object")
    #expect(evaluation.objectID == "obj-7")
    #expect(evaluation.previewProperties.map(\.name) == ["probe", "ok"])
    #expect(evaluation.previewProperties[0].value == "1124")
    #expect(throws: ShaarConsoleEvaluationError.self) {
      try ShaarConsoleModel.evaluation(from: [
        "exceptionDetails": ["exception": ["description": "boom"], "text": "Uncaught"]
      ])
    }
    let number = try ShaarConsoleModel.evaluation(from: [
      "result": ["type": "number", "value": 42, "description": "42"]
    ])
    #expect(number.message == "42")
    let text = try ShaarConsoleModel.evaluation(from: [
      "result": ["type": "string", "value": "hello"]
    ])
    #expect(text.message == "hello")
  }

  @Test func clearDropsEntriesAndKeepsHistory() async {
    let model = ShaarConsoleModel()
    var cleared = false
    model.onClear = { cleared = true }
    model.command = "1 + 1"
    await model.submit { _ in
      ShaarConsoleEvaluation(
        message: "2", objectID: "obj-1",
        previewProperties: [
          ShaarConsoleProperty(name: "n", value: "2")
        ])
    }
    #expect(model.rows(from: []).contains { $0.event.objectID == "obj-1" })
    model.clearEntries()
    #expect(cleared)
    #expect(model.rows(from: []).isEmpty)
    #expect(model.history == ["1 + 1"])
  }

  @Test func consoleToolsRenderOffscreen() throws {
    _ = NSApplication.shared
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/dashboard")!)
    let error = ShaarConsoleEvent(
      id: UUID(), level: .error, message: "GET /api/orders failed: 503",
      source: "/app/api/orders.ts:17")
    let shell = ShaarDevToolsModel(
      target: target,
      transport: ShaarDevToolsFixtureTransport(fixture: [.console(error)]),
      layoutDefaults: UserDefaults(suiteName: "ShaarConsoleTools.\(UUID().uuidString)")!)
    let inspector = InspectorModel(target: target, engine: nil)
    shell.open(inspector: inspector)
    shell.section = .console
    shell.console.searchUsesRegex = true
    shell.console.search = "("
    shell.console.preserveLog = true
    #expect(shell.console.regexIsInvalid)
    let image = try VisualCapture.pngOffscreen(
      ShaarDevToolsPanel(model: shell, inspector: inspector, openChromium: {}),
      size: NSSize(width: 850, height: 620))
    #expect(!image.isEmpty)
    shell.close()
  }
}
