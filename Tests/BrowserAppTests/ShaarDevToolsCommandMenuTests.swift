// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import Testing

@testable import ArcusisBrowser
@testable import ShaarEngineABI

@Suite struct ShaarDevToolsCommandIndexTests {
  @Test func emptyQueryListsPanelsAndDockPositions() {
    let matches = ShaarDevToolsCommandIndex.matches(
      query: "  ", sections: ShaarDevToolsSection.allCases, console: [], network: [],
      sources: [], nodes: [])
    let titles = matches.map(\.title)
    #expect(titles.first == "Elements")
    #expect(titles.contains("Dock to bottom"))
    #expect(titles.contains("Open in separate window"))
    #expect(titles.contains("Settings"))
    #expect(matches.allSatisfy { $0.hit.groupKey == nil })
  }

  @Test func queryFiltersCommandsAndFindsPageContent() {
    let console = ShaarConsoleEvent(
      id: UUID(), level: .error, message: "Dashboard failed", source: "app.ts")
    let network = ShaarNetworkRequest(
      id: "req-1", method: "GET", url: "http://localhost:3000/dashboard", status: 500,
      mimeType: nil, encodedBytes: nil, startedAt: 0, respondedAt: nil, completedAt: nil,
      failure: nil, requestHeaders: [], responseHeaders: [], payload: nil, responseBody: nil)
    let source = ShaarSourceResource(
      url: "http://localhost:3000/dashboard.js", type: "Script", mimeType: "text/javascript")
    let button = ShaarDOMNode(
      id: 4, parentID: 1, relation: .child, nodeType: 1, name: "BUTTON", value: "",
      attributes: [
        ShaarDOMAttribute(name: "id", value: "save"),
        ShaarDOMAttribute(name: "class", value: "primary"),
      ],
      childCount: 0, childrenIDs: [])
    let matches = ShaarDevToolsCommandIndex.matches(
      query: "dash", sections: [.elements, .console, .network, .sources],
      console: [console], network: [network], sources: [source], nodes: [button])
    #expect(matches.map(\.hit) == [.console(console.id), .network("req-1"), .source(source.url)])
    #expect(matches.map(\.detail) == ["app.ts", "GET 500", "Script"])
  }

  @Test func elementQueryUsesTheTagAndIdentifier() {
    let button = ShaarDOMNode(
      id: 8, parentID: nil, relation: .child, nodeType: 1, name: "BUTTON", value: "",
      attributes: [ShaarDOMAttribute(name: "id", value: "save")],
      childCount: 0, childrenIDs: [])
    let text = ShaarDOMNode(
      id: 9, parentID: 8, relation: .child, nodeType: 3, name: "#text", value: "Save changes",
      attributes: [], childCount: 0, childrenIDs: [])
    let document = ShaarDOMNode(
      id: 1, parentID: nil, relation: .child, nodeType: 9, name: "#document", value: "",
      attributes: [], childCount: 1, childrenIDs: [8])
    let matches = ShaarDevToolsCommandIndex.matches(
      query: "save", sections: [], console: [], network: [], sources: [],
      nodes: [document, text, button])
    #expect(matches.map(\.title) == ["button#save", "Save changes"])
  }

  @Test func contentHitsKeepTheNewestMatchesWithinTheScan() {
    let events = (0..<8).map { index in
      ShaarConsoleEvent(
        id: UUID(), level: .log, message: "ready \(index)", source: nil)
    }
    let matches = ShaarDevToolsCommandIndex.matches(
      query: "ready", sections: [], console: events, network: [], sources: [], nodes: [])
    #expect(matches.count == ShaarDevToolsCommandIndex.contentLimit)
    #expect(matches.first?.title == "ready 7")
    #expect(matches.last?.title == "ready 2")
  }
}

@Suite @MainActor struct ShaarDevToolsCommandMenuModelTests {
  @Test func choosingAHitSwitchesThePanelAndSelectsTheRow() async throws {
    let consoleID = UUID()
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/")!)
    let defaults = UserDefaults(suiteName: "ShaarDevToolsCommandMenu.\(UUID().uuidString)")!
    let shell = ShaarDevToolsModel(
      target: target,
      transport: CommandMenuFixtureTransport(consoleID: consoleID),
      layoutDefaults: defaults)
    let inspector = InspectorModel(target: target, engine: nil)
    shell.open(inspector: inspector)
    for _ in 0..<20 where shell.events.isEmpty { await Task.yield() }
    shell.toggleCommandMenu()
    #expect(shell.commandMenuOpen)
    shell.commandQuery = "dashboard"
    let match = try #require(shell.commandMatches.first { $0.hit == .console(consoleID) })
    shell.perform(match)
    #expect(!shell.commandMenuOpen)
    #expect(shell.section == .console)
    #expect(shell.console.selectedID == consoleID)

    shell.toggleCommandMenu()
    shell.perform(
      ShaarDevToolsCommandMatch(hit: .dock(.bottom), title: "Dock to bottom", detail: ""))
    #expect(shell.dock == .bottom)
    #expect(!shell.commandMenuOpen)
    shell.close()
  }

  @Test func arrowKeysStayInsideTheMatchList() {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/")!)
    let defaults = UserDefaults(suiteName: "ShaarDevToolsCommandMenu.\(UUID().uuidString)")!
    let shell = ShaarDevToolsModel(target: target, layoutDefaults: defaults)
    shell.toggleCommandMenu()
    shell.moveCommandSelection(forward: false)
    #expect(shell.commandSelection == 0)
    shell.moveCommandSelection(forward: true)
    #expect(shell.commandSelection == 1)
    let last = shell.commandMatches.count - 1
    shell.commandSelection = last
    shell.moveCommandSelection(forward: true)
    #expect(shell.commandSelection == last)
  }
}

@Test func commandMenuShortcutIsCommandShiftP() {
  #expect(isCommandMenu(35, [.command, .shift]))
  #expect(isCommandMenu(35, [.command, .shift, .function]))
  #expect(!isCommandMenu(35, [.command]))
  #expect(!isCommandMenu(35, [.option, .shift]))
  #expect(!isCommandMenu(35, [.command, .shift, .control]))
  #expect(!isCommandMenu(34, [.command, .shift]))
}

private func isCommandMenu(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> Bool {
  ShaarDevToolsShortcut.isCommandMenu(keyCode: keyCode, modifiers: modifiers)
}

private struct CommandMenuFixtureTransport: ShaarDevToolsEventTransport {
  let consoleID: UUID

  func messages(for target: SiteControlTarget) -> AsyncStream<ShaarDevToolsTransportMessage> {
    AsyncStream { continuation in
      continuation.yield(.streamAvailable)
      continuation.yield(
        .event(
          .console(
            ShaarConsoleEvent(
              id: consoleID, level: .error, message: "Dashboard failed", source: "app.ts"))))
      continuation.yield(
        .event(
          .network(
            ShaarNetworkEvent(
              id: UUID(), method: "GET", url: "http://localhost:3000/dashboard", status: 500))))
      continuation.finish()
    }
  }
}
