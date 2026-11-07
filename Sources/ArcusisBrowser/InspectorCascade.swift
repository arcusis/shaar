// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

struct InspectorSpecificity: Equatable {
  var a = 0
  var b = 0
  var c = 0

  func beats(_ other: InspectorSpecificity) -> Bool {
    if a != other.a { return a > other.a }
    if b != other.b { return b > other.b }
    return c > other.c
  }
}

enum InspectorCascade {
  struct Trace: Equatable {
    let ruleID: Int
    let selector: String
    let source: String
  }

  /// The declaration that won `property`, when the matched rules Shaar stored are enough to say.
  static func trace(for property: String, rules: [InspectorRule]) -> Trace? {
    let name = property.lowercased()
    let grouped = Dictionary(grouping: rules.filter { generation($0) >= 0 }, by: generation)
    if let own = grouped[0], let hit = winner(among: own, property: name) {
      return trace(hit)
    }
    guard inherits(name) else { return nil }
    for distance in grouped.keys.filter({ $0 > 0 }).sorted() {
      guard let generation = grouped[distance], let hit = winner(among: generation, property: name)
      else { continue }
      return trace(hit)
    }
    return nil
  }

  static func specificity(matching row: [String: Any]) -> InspectorSpecificity {
    guard let rule = row["rule"] as? [String: Any],
      let list = rule["selectorList"] as? [String: Any],
      let selectors = list["selectors"] as? [[String: Any]]
    else { return InspectorSpecificity() }
    var best = InspectorSpecificity()
    var found = false
    for index in indexes(row["matchingSelectors"]) {
      guard selectors.indices.contains(index) else { continue }
      let candidate = specificity(selectors[index]["specificity"])
      if !found || candidate.beats(best) {
        best = candidate
        found = true
      }
    }
    return best
  }

  private static func generation(_ rule: InspectorRule) -> Int {
    if rule.note.hasPrefix("::") { return -1 }
    if rule.note == "Inherited" {
      return rule.distance == 0 ? 1 : rule.distance
    }
    return rule.distance
  }

  private static func inherits(_ property: String) -> Bool {
    property.hasPrefix("--") || inheritedProperties.contains(property)
  }

  private static func winner(among rules: [InspectorRule], property: String) -> Hit? {
    var best: Hit?
    var bestRank: Rank?
    for rule in rules {
      for (index, declaration) in rule.declarations.enumerated() {
        if declaration.disabled { continue }
        if !affects(declaration: declaration.name, property: property) { continue }
        let rank = Rank(rule: rule, declaration: declaration, index: index)
        if let bestRank, rank <= bestRank { continue }
        best = Hit(rule: rule)
        bestRank = rank
      }
    }
    return best
  }

  private static func affects(declaration name: String, property: String) -> Bool {
    if name == property { return true }
    return longhands[name]?.contains(property) == true
  }

  private static func trace(_ hit: Hit) -> Trace {
    Trace(ruleID: hit.rule.id, selector: hit.rule.selector, source: hit.rule.source)
  }

  private struct Hit {
    let rule: InspectorRule
  }

  /// Higher ranks win. Bands follow origin and importance; inline style outranks selectors in its band.
  private struct Rank: Comparable {
    var band: Int
    var inline: Int
    var a: Int
    var b: Int
    var c: Int
    var order: Int
    var position: Int

    init(rule: InspectorRule, declaration: InspectorDeclaration, index: Int) {
      band = Self.band(origin: rule.origin, important: declaration.important)
      inline = rule.origin == .inline ? 1 : 0
      a = rule.specificity.a
      b = rule.specificity.b
      c = rule.specificity.c
      order = rule.cascadeOrder
      position = index
    }

    static func < (lhs: Rank, rhs: Rank) -> Bool {
      if lhs.band != rhs.band { return lhs.band < rhs.band }
      if lhs.inline != rhs.inline { return lhs.inline < rhs.inline }
      if lhs.a != rhs.a { return lhs.a < rhs.a }
      if lhs.b != rhs.b { return lhs.b < rhs.b }
      if lhs.c != rhs.c { return lhs.c < rhs.c }
      if lhs.order != rhs.order { return lhs.order < rhs.order }
      return lhs.position < rhs.position
    }

    private static func band(origin: InspectorRuleOrigin, important: Bool) -> Int {
      if important {
        if origin == .userAgent { return 3 }
        return 2
      }
      if origin == .userAgent { return 0 }
      return 1
    }
  }

  private static func indexes(_ value: Any?) -> [Int] {
    if let values = value as? [Int] { return values }
    if let values = value as? [NSNumber] { return values.map(\.intValue) }
    return []
  }

  private static func specificity(_ value: Any?) -> InspectorSpecificity {
    guard let spec = value as? [String: Any] else { return InspectorSpecificity() }
    return InspectorSpecificity(
      a: integer(spec["a"]), b: integer(spec["b"]), c: integer(spec["c"]))
  }

  private static func integer(_ value: Any?) -> Int {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    return 0
  }

  private static let inheritedProperties: Set<String> = [
    "border-collapse", "border-spacing", "caption-side", "caret-color", "color", "cursor",
    "direction", "empty-cells", "font-family", "font-feature-settings", "font-kerning",
    "font-optical-sizing", "font-size", "font-size-adjust", "font-stretch", "font-style",
    "font-synthesis", "font-variant", "font-weight", "hyphens", "letter-spacing", "line-height",
    "list-style-image", "list-style-position", "list-style-type", "orphans", "overflow-wrap",
    "pointer-events", "quotes", "tab-size", "text-align", "text-align-last", "text-indent",
    "text-justify", "text-shadow", "text-transform", "visibility", "white-space", "widows",
    "word-break", "word-spacing", "writing-mode",
  ]

  private static let longhands: [String: Set<String>] = [
    "margin": sideEdges("margin"),
    "padding": sideEdges("padding"),
    "border-width": sideEdges("border", suffix: "width"),
    "border-style": sideEdges("border", suffix: "style"),
    "border-color": sideEdges("border", suffix: "color"),
    "border": borderEdges(),
    "border-top": borderSide("top"),
    "border-right": borderSide("right"),
    "border-bottom": borderSide("bottom"),
    "border-left": borderSide("left"),
    "border-radius": [
      "border-top-left-radius", "border-top-right-radius", "border-bottom-right-radius",
      "border-bottom-left-radius",
    ],
    "overflow": ["overflow-x", "overflow-y"],
    "inset": ["top", "right", "bottom", "left"],
    "gap": ["row-gap", "column-gap"],
    "font": [
      "font-style", "font-variant", "font-weight", "font-stretch", "font-size", "line-height",
      "font-family",
    ],
    "background": [
      "background-color", "background-image", "background-repeat", "background-attachment",
      "background-position", "background-size", "background-origin", "background-clip",
    ],
    "flex": ["flex-grow", "flex-shrink", "flex-basis"],
    "flex-flow": ["flex-direction", "flex-wrap"],
    "outline": ["outline-color", "outline-style", "outline-width"],
    "list-style": ["list-style-type", "list-style-position", "list-style-image"],
    "place-items": ["align-items", "justify-items"],
    "place-content": ["align-content", "justify-content"],
    "place-self": ["align-self", "justify-self"],
  ]

  private static func sideEdges(_ name: String) -> Set<String> {
    Set(["top", "right", "bottom", "left"].map { "\(name)-\($0)" })
  }

  private static func sideEdges(_ name: String, suffix: String) -> Set<String> {
    Set(["top", "right", "bottom", "left"].map { "\(name)-\($0)-\(suffix)" })
  }

  private static func borderSide(_ side: String) -> Set<String> {
    Set(["width", "style", "color"].map { "border-\(side)-\($0)" })
  }

  private static func borderEdges() -> Set<String> {
    Set(
      ["width", "style", "color"].flatMap { suffix in
        ["top", "right", "bottom", "left"].map { "border-\($0)-\(suffix)" }
      })
  }
}
