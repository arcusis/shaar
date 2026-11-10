// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import Testing

@testable import ArcusisBrowser
@testable import ShaarEngineABI

@Suite @MainActor struct ShaarDevToolsCommandIndexTests {
  @Test func emptyQueryListsPanelsAndDockPositions() {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com")!)
    let shell = ShaarDevToolsModel(target: target)
    let matches = ShaarDevToolsCommandIndex.matches(
      query: "  ", sections: shell.sections, sources: [], nodes: [])
    let titles = matches.map(\.title)
    #expect(titles.first == "Elements")
    #expect(titles.contains("Issues"))
    #expect(titles.contains("Audits"))
    #expect(titles.contains("Security"))
    #expect(titles.contains("Sensors"))
    #expect(titles.contains("Rendering"))
    #expect(titles.contains("CSS overview"))
    #expect(titles.contains("Coverage"))
    #expect(titles.contains("Recorder"))
    #expect(titles.contains("Dock to bottom"))
    #expect(titles.contains("Open in separate window"))
    #expect(titles.contains("Settings"))
    #expect(matches.allSatisfy { $0.hit.groupKey == nil })
  }

  @Test func queryFiltersCommandsAndFindsPageContent() {
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
      query: "dash", sections: [.elements, .sources], sources: [source], nodes: [button])
    #expect(matches.map(\.hit) == [.source(source.url)])
    #expect(matches.map(\.detail) == ["Script"])
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
      query: "save", sections: [], sources: [], nodes: [document, text, button])
    #expect(matches.map(\.title) == ["button#save", "Save changes"])
  }

}

@Suite @MainActor struct ShaarDevToolsCommandMenuModelTests {
  @Test func choosingAHitDoesNotRouteToARetiredPanel() async throws {
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/")!)
    let defaults = UserDefaults(suiteName: "ShaarDevToolsCommandMenu.\(UUID().uuidString)")!
    let shell = ShaarDevToolsModel(
      target: target,
      layoutDefaults: defaults)
    shell.toggleCommandMenu()
    #expect(shell.commandMenuOpen)
    shell.commandQuery = "console"
    #expect(shell.commandMatches.isEmpty)
    shell.closeCommandMenu()
    #expect(shell.section != .console)
    #expect(shell.section != .network)

    shell.toggleCommandMenu()
    shell.perform(
      ShaarDevToolsCommandMatch(hit: .dock(.bottom), title: "Dock to bottom", detail: ""))
    #expect(shell.dock == .bottom)
    #expect(!shell.commandMenuOpen)
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
