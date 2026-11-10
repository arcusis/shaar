// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import Foundation
import ShaarEngineABI

enum ShaarDevToolsCommandHit: Equatable {
  case section(ShaarDevToolsSection)
  case dock(ShaarDevToolsDock)
  case element(Int)
  case settings

  var token: String {
    switch self {
    case .section(let section): "section:\(section.rawValue)"
    case .dock(let dock): "dock:\(dock.rawValue)"
    case .element(let id): "element:\(id)"
    case .settings: "settings"
    }
  }

  var groupKey: String? {
    switch self {
    case .section, .dock: nil
    case .element: "Elements"
    case .settings: nil
    }
  }

  var localizesTitle: Bool {
    switch self {
    case .section, .dock, .settings: true
    case .element: false
    }
  }
}

struct ShaarDevToolsCommandMatch: Equatable, Identifiable {
  let hit: ShaarDevToolsCommandHit
  let title: String
  let detail: String
  var id: String { hit.token }
}

@MainActor
enum ShaarDevToolsCommandShortcut {
  @discardableResult
  static func toggleFloating(
    shells: some Sequence<ShaarDevToolsModel>, window: NSWindow?
  ) -> Bool {
    guard let window else { return false }
    for shell in shells where shell.isOpen && shell.floatingWindow?.isWindow(window) == true {
      shell.toggleCommandMenu()
      return true
    }
    return false
  }
}

enum ShaarDevToolsCommandIndex {
  static let contentLimit = 6
  static let scanLimit = 2_000

  static func matches(
    query: String,
    sections: [ShaarDevToolsSection],
    nodes: [ShaarDOMNode]
  ) -> [ShaarDevToolsCommandMatch] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    var result = actions(needle: needle, sections: sections)
    guard !needle.isEmpty else { return result }
    result += elementHits(needle, nodes: nodes)
    return result
  }

  private static func actions(needle: String, sections: [ShaarDevToolsSection])
    -> [ShaarDevToolsCommandMatch]
  {
    var result: [ShaarDevToolsCommandMatch] = []
    for section in sections where matches(needle, section.rawValue) {
      result.append(
        ShaarDevToolsCommandMatch(
          hit: .section(section), title: section.rawValue, detail: ""))
    }
    for dock in ShaarDevToolsDock.allCases where matches(needle, dock.rawValue) {
      result.append(ShaarDevToolsCommandMatch(hit: .dock(dock), title: dock.rawValue, detail: ""))
    }
    if matches(needle, "Settings") {
      result.append(ShaarDevToolsCommandMatch(hit: .settings, title: "Settings", detail: ""))
    }
    return result
  }

  private static func elementHits(_ needle: String, nodes: [ShaarDOMNode])
    -> [ShaarDevToolsCommandMatch]
  {
    var result: [ShaarDevToolsCommandMatch] = []
    for node in nodes.sorted(by: { $0.id < $1.id }) {
      guard result.count < contentLimit else { break }
      guard node.nodeType == 1 || node.nodeType == 3 else { continue }
      guard matches(needle, elementFields(node)) else { continue }
      let title = elementLabel(node)
      guard !title.isEmpty else { continue }
      result.append(
        ShaarDevToolsCommandMatch(hit: .element(node.id), title: title, detail: ""))
    }
    return result
  }

  private static func elementLabel(_ node: ShaarDOMNode) -> String {
    if node.nodeType == 3 {
      return node.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let tag = node.name.lowercased()
    let identifier = node.attributes.first { $0.name == "id" }?.value ?? ""
    guard !identifier.isEmpty else { return tag }
    return "\(tag)#\(identifier)"
  }

  private static func elementFields(_ node: ShaarDOMNode) -> [String] {
    var fields = [node.name, node.value]
    for attribute in node.attributes where attribute.name == "id" || attribute.name == "class" {
      fields.append(attribute.value)
    }
    return fields
  }

  private static func matches(_ needle: String, _ fields: String...) -> Bool {
    matches(needle, fields)
  }

  private static func matches(_ needle: String, _ fields: [String]) -> Bool {
    guard !needle.isEmpty else { return true }
    return fields.contains { $0.localizedStandardContains(needle) }
  }
}
