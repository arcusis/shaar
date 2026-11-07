// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite struct ShaarDevToolsIssuesListTests {
  @Test func twoIdenticalConsoleErrorsCountAsOneIssue() {
    let first = UUID()
    let events = [
      console(first, .error, "Dashboard failed"),
      console(UUID(), .log, "ready"),
      console(UUID(), .error, "Dashboard failed"),
      console(UUID(), .warning, "Slow response"),
    ]
    let issues = ShaarDevToolsIssues.list(console: events, requests: [])
    #expect(issues.count == 2)
    #expect(issues[0].count == 2)
    #expect(issues[0].title == "Dashboard failed")
    if case .console(let id, let level) = issues[0].kind {
      #expect(id == first)
      #expect(level == .error)
    } else {
      Issue.record("Expected a console issue")
    }
    #expect(issues[1].title == "Slow response")
  }

  @Test func aFailedRequestIsListed() {
    let failed = ShaarNetworkRequest(
      id: "req-1", method: "GET", url: "http://localhost:3000/api", status: 500,
      mimeType: nil, encodedBytes: nil, startedAt: 0, respondedAt: nil, completedAt: 1,
      failure: nil, requestHeaders: [], responseHeaders: [], payload: nil, responseBody: nil)
    let ok = ShaarNetworkRequest(
      id: "req-2", method: "GET", url: "http://localhost:3000/app.js", status: 200,
      mimeType: nil, encodedBytes: nil, startedAt: 0, respondedAt: nil, completedAt: 1,
      failure: nil, requestHeaders: [], responseHeaders: [], payload: nil, responseBody: nil)
    let issues = ShaarDevToolsIssues.list(console: [], requests: [failed, ok])
    #expect(issues.count == 1)
    #expect(issues[0].title == "api")
    #expect(issues[0].detail == "GET 500")
    let cancelled = ShaarNetworkRequest(
      id: "req-3", method: "POST", url: "http://localhost:3000/save", status: nil,
      mimeType: nil, encodedBytes: nil, startedAt: 0, respondedAt: nil, completedAt: 1,
      failure: "cancelled", requestHeaders: [], responseHeaders: [], payload: nil,
      responseBody: nil)
    let unnamed = ShaarNetworkRequest(
      id: "req-4", method: "GET", url: "http://localhost:3000/hang", status: nil,
      mimeType: nil, encodedBytes: nil, startedAt: 0, respondedAt: nil, completedAt: nil,
      failure: "", requestHeaders: [], responseHeaders: [], payload: nil, responseBody: nil)
    let details = ShaarDevToolsIssues.list(console: [], requests: [cancelled, unnamed])
    #expect(details.map(\.detail) == ["POST cancelled", "GET"])
    #expect(ShaarDevToolsIssues.countText(2) == "2")
    #expect(ShaarDevToolsIssues.countText(100) == "99+")
    if case .network(let id, let status, _) = issues[0].kind {
      #expect(id == "req-1")
      #expect(status == 500)
    } else {
      Issue.record("Expected a network issue")
    }
  }
}

@Suite @MainActor struct ShaarDevToolsIssuesModelTests {
  @Test func choosingARowSelectsTheRightPanel() async throws {
    let errorID = UUID()
    let defaults = UserDefaults(suiteName: "ShaarDevToolsIssues.\(UUID().uuidString)")!
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/")!)
    let shell = ShaarDevToolsModel(
      target: target, transport: IssuesFixtureTransport(errorID: errorID), layoutDefaults: defaults)
    shell.open(inspector: InspectorModel(target: target, engine: nil))
    for _ in 0..<40 where shell.issues.count < 2 { await Task.yield() }
    #expect(shell.issues.count == 2)
    let consoleIssue = try #require(
      shell.issues.first { issue in
        if case .console = issue.kind { return true }
        return false
      })
    shell.openIssue(consoleIssue)
    #expect(shell.section == .console)
    #expect(shell.console.selectedID == errorID)

    let networkIssue = try #require(
      shell.issues.first { issue in
        if case .network = issue.kind { return true }
        return false
      })
    shell.openIssue(networkIssue)
    #expect(shell.section == .network)
    #expect(shell.network.selectedID == "req-9")
    shell.close()
  }

  @Test func issuesPanelRendersOffscreenEmptyAndPopulated() async throws {
    _ = NSApplication.shared
    let defaults = UserDefaults(suiteName: "ShaarDevToolsIssues.\(UUID().uuidString)")!
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/")!)
    let emptyShell = ShaarDevToolsModel(target: target, layoutDefaults: defaults)
    let empty = try VisualCapture.pngOffscreen(
      ShaarDevToolsIssuesPanel(model: emptyShell), size: NSSize(width: 640, height: 240))
    let shell = ShaarDevToolsModel(
      target: target, transport: IssuesFixtureTransport(errorID: UUID()), layoutDefaults: defaults)
    let inspector = InspectorModel(target: target, engine: nil)
    shell.open(inspector: inspector)
    shell.section = .issues
    for _ in 0..<40 where shell.issues.count < 2 { await Task.yield() }
    #expect(shell.issues.count == 2)
    let populated = try VisualCapture.pngOffscreen(
      ShaarDevToolsIssuesPanel(model: shell), size: NSSize(width: 640, height: 240))
    let panel = try VisualCapture.pngOffscreen(
      ShaarDevToolsPanel(model: shell, inspector: inspector, openChromium: {}),
      size: NSSize(width: 850, height: 620))
    #expect(!empty.isEmpty)
    #expect(!populated.isEmpty)
    #expect(!panel.isEmpty)
    shell.close()
  }
}

private func console(_ id: UUID, _ level: ShaarConsoleEvent.Level, _ message: String)
  -> ShaarConsoleEvent
{
  ShaarConsoleEvent(id: id, level: level, message: message, source: "app.ts")
}

private struct IssuesFixtureTransport: ShaarDevToolsEventTransport {
  let errorID: UUID

  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarDevToolsTransportMessage> {
    AsyncStream { continuation in
      continuation.yield(.streamAvailable)
      continuation.yield(
        .event(
          .console(
            ShaarConsoleEvent(
              id: errorID, level: .error, message: "Dashboard failed", source: "app.ts"))))
      continuation.yield(
        .event(
          .console(
            ShaarConsoleEvent(
              id: UUID(), level: .error, message: "Dashboard failed", source: "app.ts"))))
      continuation.yield(
        .event(
          .network(
            ShaarNetworkEvent(
              id: UUID(), method: "GET", url: "http://localhost:3000/api", status: 500,
              requestID: "req-9"))))
      continuation.finish()
    }
  }
}
