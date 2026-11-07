// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import ShaarEngineABI

/// Short CSS and XPath for a DOM node, using the same rules as the Inspector page script.
/// Queries stay in the light tree: shadow roots and frame documents are separate documents.
enum ShaarDOMLocator {
  static func css(for id: Int, nodes: [Int: ShaarDOMNode]) -> String {
    guard pathIsComplete(id, nodes: nodes), let node = nodes[id], node.nodeType == 1 else {
      return ""
    }
    for seed in seeds(of: node) where unique(steps: [(seed.simple, nil)], target: id, nodes: nodes)
    {
      return seed.text
    }
    var candidates: [String] = []
    var chain: [Piece] = []
    var current: Int? = id
    var depth = 0
    while let value = current, let element = nodes[value], element.nodeType == 1, depth < 256 {
      depth += 1
      chain.append(piece(for: value, nodes: nodes))
      let suffix = Array(chain.reversed())
      if unique(steps: childSteps(suffix), target: id, nodes: nodes) {
        candidates.append(suffix.map(\.text).joined(separator: " > "))
      }
      if value != id {
        candidates.append(
          contentsOf: anchoredCandidates(
            of: element, rest: Array(chain.dropLast().reversed()), target: id, nodes: nodes))
      }
      current = parentElement(value, nodes: nodes)
    }
    return shortest(candidates)
  }

  static func xpath(for id: Int, nodes: [Int: ShaarDOMNode]) -> String {
    guard pathIsComplete(id, nodes: nodes), let node = nodes[id], node.nodeType == 1 else {
      return ""
    }
    if let identifier = attribute(node, "id"), !identifier.isEmpty,
      unique(steps: [(Simple.id(identifier), nil)], target: id, nodes: nodes)
    {
      return "//*[@id=\(xpathLiteral(identifier))]"
    }
    var parts: [String] = []
    var current: Int? = id
    var depth = 0
    while let value = current, nodes[value]?.nodeType == 1, depth < 256 {
      depth += 1
      let name = nodes[value]?.name.lowercased() ?? ""
      let index = nthOfType(value, nodes: nodes)
      parts.insert("*[local-name()=\(xpathLiteral(name))][\(index)]", at: 0)
      current = parentElement(value, nodes: nodes)
    }
    if current != nil { return "" }
    return "/" + parts.joined(separator: "/")
  }

  private struct Piece {
    let simple: Simple
    let text: String
  }

  private enum Simple {
    case id(String)
    case attribute(String, String)
    case tag(String, nth: Int?)
  }

  private struct Seed {
    let simple: Simple
    let text: String
  }

  private enum Combinator {
    case child
    case descendant

    var separator: String {
      switch self {
      case .child: " > "
      case .descendant: " "
      }
    }
  }

  private static func pathIsComplete(_ id: Int, nodes: [Int: ShaarDOMNode]) -> Bool {
    guard nodes[id]?.nodeType == 1 else { return false }
    var current: Int? = id
    var depth = 0
    while let value = current, depth < 256 {
      depth += 1
      if let parentID = nodes[value]?.parentID, let parent = nodes[parentID],
        parent.childrenIDs.count < parent.childCount
      {
        return false
      }
      current = nodes[value]?.parentID
    }
    return true
  }

  private static func seeds(of node: ShaarDOMNode) -> [Seed] {
    var result: [Seed] = []
    if let identifier = attribute(node, "id"), !identifier.isEmpty {
      result.append(Seed(simple: .id(identifier), text: "#" + cssEscape(identifier)))
    }
    let names = [
      "data-testid", "data-test", "data-qa", "aria-label", "aria-labelledby", "title", "alt",
      "name", "role",
    ]
    for name in names {
      guard let value = attribute(node, name), !value.isEmpty else { continue }
      result.append(
        Seed(simple: .attribute(name, value), text: "[\(name)=\(cssEscape(value))]"))
    }
    return result
  }

  private static func piece(for id: Int, nodes: [Int: ShaarDOMNode]) -> Piece {
    let name = nodes[id]?.name.lowercased() ?? ""
    let escaped = cssEscape(name)
    let sameName = sameTagSiblings(id, nodes: nodes)
    if sameName.count > 1 {
      let index = (sameName.firstIndex { $0.id == id } ?? 0) + 1
      return Piece(simple: .tag(name, nth: index), text: "\(escaped):nth-of-type(\(index))")
    }
    return Piece(simple: .tag(name, nth: nil), text: escaped)
  }

  private static func anchoredCandidates(
    of element: ShaarDOMNode, rest: [Piece], target: Int, nodes: [Int: ShaarDOMNode]
  ) -> [String] {
    guard !rest.isEmpty else { return [] }
    var found: [String] = []
    for seed in seeds(of: element) {
      for join in [Combinator.child, .descendant] {
        let text = seed.text + join.separator + rest.map(\.text).joined(separator: " > ")
        let steps = anchoredSteps(seed: seed, rest: rest, join: join)
        if unique(steps: steps, target: target, nodes: nodes) {
          found.append(text)
        }
      }
    }
    return found
  }

  private static func anchoredSteps(
    seed: Seed, rest: [Piece], join: Combinator
  ) -> [(Simple, Combinator?)] {
    var steps: [(Simple, Combinator?)] = [(seed.simple, nil)]
    for (index, piece) in rest.enumerated() {
      let combinator: Combinator = index == 0 ? join : .child
      steps.append((piece.simple, combinator))
    }
    return steps
  }

  private static func childSteps(_ pieces: [Piece]) -> [(Simple, Combinator?)] {
    pieces.enumerated().map { index, piece in
      (piece.simple, index == 0 ? nil : Combinator.child)
    }
  }

  private static func shortest(_ candidates: [String]) -> String {
    candidates.min { lhs, rhs in
      let left = lhs.utf16.count
      let right = rhs.utf16.count
      if left != right { return left < right }
      return lhs < rhs
    } ?? ""
  }

  private static func unique(
    steps: [(Simple, Combinator?)], target: Int, nodes: [Int: ShaarDOMNode]
  ) -> Bool {
    let found = query(steps, nodes: nodes)
    return found.count == 1 && found[0] == target
  }

  private static func query(_ steps: [(Simple, Combinator?)], nodes: [Int: ShaarDOMNode]) -> [Int] {
    guard let first = steps.first else { return [] }
    let elements = lightElements(nodes: nodes)
    var matched = Set(elements.filter { matches($0, first.0, nodes: nodes) })
    for step in steps.dropFirst() {
      let combinator = step.1 ?? .descendant
      matched = Set(
        elements.filter { id in
          guard matches(id, step.0, nodes: nodes) else { return false }
          return related(id, to: matched, by: combinator, nodes: nodes)
        })
    }
    return elements.filter { matched.contains($0) }
  }

  private static func related(
    _ id: Int, to matched: Set<Int>, by combinator: Combinator, nodes: [Int: ShaarDOMNode]
  ) -> Bool {
    switch combinator {
    case .child:
      guard let parent = parentElement(id, nodes: nodes) else { return false }
      return matched.contains(parent)
    case .descendant:
      var parent = parentElement(id, nodes: nodes)
      while let value = parent {
        if matched.contains(value) { return true }
        parent = parentElement(value, nodes: nodes)
      }
      return false
    }
  }

  private static func matches(_ id: Int, _ simple: Simple, nodes: [Int: ShaarDOMNode]) -> Bool {
    guard let node = nodes[id], node.nodeType == 1 else { return false }
    switch simple {
    case .id(let value):
      return attribute(node, "id") == value
    case .attribute(let name, let value):
      return attribute(node, name) == value
    case .tag(let name, let nth):
      guard node.name.lowercased() == name else { return false }
      guard let nth else { return true }
      return nthOfType(id, nodes: nodes) == nth
    }
  }

  private static func lightElements(nodes: [Int: ShaarDOMNode]) -> [Int] {
    guard let root = nodes.values.first(where: { $0.parentID == nil })?.id else { return [] }
    var result: [Int] = []
    func walk(_ id: Int) {
      guard let node = nodes[id] else { return }
      if node.nodeType == 1, node.relation == .child { result.append(id) }
      let descends = node.nodeType == 9 || node.nodeType == 1
      guard descends else { return }
      for child in node.childrenIDs where nodes[child]?.relation == .child {
        walk(child)
      }
    }
    walk(root)
    return result
  }

  private static func parentElement(_ id: Int, nodes: [Int: ShaarDOMNode]) -> Int? {
    guard let node = nodes[id], node.nodeType == 1, node.relation == .child,
      let parentID = node.parentID, nodes[parentID]?.nodeType == 1
    else { return nil }
    return parentID
  }

  private static func sameTagSiblings(_ id: Int, nodes: [Int: ShaarDOMNode]) -> [ShaarDOMNode] {
    guard let node = nodes[id] else { return [] }
    let name = node.name.lowercased()
    guard let parent = parentElement(id, nodes: nodes) else { return [node] }
    return elementChildren(parent, nodes: nodes).filter { $0.name.lowercased() == name }
  }

  private static func nthOfType(_ id: Int, nodes: [Int: ShaarDOMNode]) -> Int {
    let siblings = sameTagSiblings(id, nodes: nodes)
    return (siblings.firstIndex { $0.id == id } ?? 0) + 1
  }

  private static func elementChildren(_ id: Int, nodes: [Int: ShaarDOMNode]) -> [ShaarDOMNode] {
    guard let node = nodes[id] else { return [] }
    return node.childrenIDs.compactMap { nodes[$0] }.filter {
      $0.nodeType == 1 && $0.relation == .child
    }
  }

  private static func attribute(_ node: ShaarDOMNode, _ name: String) -> String? {
    node.attributes.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
  }

  /// CSSOM `CSS.escape`, so attribute and id selectors match the Inspector script.
  private static func cssEscape(_ value: String) -> String {
    let units = Array(value.utf16)
    guard let first = units.first else { return "" }
    var result = ""
    for (index, unit) in units.enumerated() {
      if unit == 0 {
        result.append("\u{FFFD}")
        continue
      }
      if escapesAsHex(unit, index: index, first: first) {
        result.append("\\\(String(unit, radix: 16)) ")
        continue
      }
      if index == 0, units.count == 1, unit == 0x002D {
        result.append("\\-")
        continue
      }
      if isPlainIdentUnit(unit) {
        result.append(identCharacter(unit))
        continue
      }
      result.append("\\")
      result.append(identCharacter(unit))
    }
    return result
  }

  private static func escapesAsHex(_ unit: UInt16, index: Int, first: UInt16) -> Bool {
    if unit >= 0x0001, unit <= 0x001F { return true }
    if unit == 0x007F { return true }
    if index == 0, unit >= 0x0030, unit <= 0x0039 { return true }
    return index == 1 && unit >= 0x0030 && unit <= 0x0039 && first == 0x002D
  }

  private static func isPlainIdentUnit(_ unit: UInt16) -> Bool {
    if unit >= 0x0080 || unit == 0x002D || unit == 0x005F { return true }
    if unit >= 0x0030, unit <= 0x0039 { return true }
    if unit >= 0x0041, unit <= 0x005A { return true }
    return unit >= 0x0061 && unit <= 0x007A
  }

  private static func identCharacter(_ unit: UInt16) -> Character {
    guard let scalar = UnicodeScalar(UInt32(unit)) else { return "\u{FFFD}" }
    return Character(scalar)
  }

  private static func xpathLiteral(_ value: String) -> String {
    if !value.contains("'") { return "'\(value)'" }
    if !value.contains("\"") { return "\"\(value)\"" }
    let parts = value.split(separator: "'", omittingEmptySubsequences: false).map { part in
      "'\(part)'"
    }
    return "concat(" + parts.joined(separator: ",\"'\",") + ")"
  }
}
