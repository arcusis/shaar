// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite struct InspectorCascadeTests {
  @Test func importantAuthorBeatsAMoreSpecificNormalRule() {
    let rules = [
      rule(1, "button", order: 1, specificity: (0, 0, 1), color: "white"),
      rule(2, "button", order: 2, specificity: (0, 0, 1), color: "blue", important: true),
      rule(3, "#save", order: 3, specificity: (1, 0, 0), color: "red"),
    ]
    let trace = InspectorCascade.trace(for: "color", rules: rules)
    #expect(trace?.ruleID == 2)
    #expect(trace?.selector == "button")
    #expect(trace?.source == "style-2")
  }

  @Test func specificityAndSourceOrderBreakAuthorTies() {
    let earlier = rule(1, "button", order: 1, specificity: (0, 0, 1), color: "white")
    let later = rule(2, "button", order: 4, specificity: (0, 0, 1), color: "black")
    let identified = rule(3, "#save", order: 2, specificity: (1, 0, 0), color: "red")
    #expect(InspectorCascade.trace(for: "color", rules: [earlier, later])?.ruleID == 2)
    #expect(InspectorCascade.trace(for: "color", rules: [later, identified])?.ruleID == 3)
  }

  @Test func inlineStyleLosesToAuthorImportantAndBeatsAuthorNormal() {
    let inline = rule(
      0, "element.style", order: 0, specificity: (0, 0, 0), color: "green", origin: .inline)
    let author = rule(1, "#save", order: 3, specificity: (1, 0, 0), color: "red")
    let important = rule(
      2, "button", order: 1, specificity: (0, 0, 1), color: "blue", important: true)
    #expect(InspectorCascade.trace(for: "color", rules: [inline, author])?.ruleID == 0)
    #expect(InspectorCascade.trace(for: "color", rules: [inline, important])?.ruleID == 2)
  }

  @Test func userAgentImportantOutranksAuthorImportant() {
    let author = rule(
      1, "#save", order: 2, specificity: (1, 0, 0), color: "red", important: true)
    let agent = rule(
      2, "button", order: 1, specificity: (0, 0, 1), color: "canvastext", origin: .userAgent,
      important: true, source: "Browser default")
    let trace = InspectorCascade.trace(for: "color", rules: [author, agent])
    #expect(trace?.ruleID == 2)
    #expect(trace?.source == "Browser default")
  }

  @Test func shorthandAndLaterLonghandShareTheCascade() {
    var padding = rule(1, "button", order: 1, specificity: (0, 0, 1), color: "white")
    padding.declarations = [.init(name: "padding", value: "10px 20px")]
    var top = rule(2, "#save", order: 2, specificity: (1, 0, 0), color: "red")
    top.declarations = [.init(name: "padding-top", value: "4px")]
    #expect(InspectorCascade.trace(for: "padding-top", rules: [padding])?.ruleID == 1)
    #expect(InspectorCascade.trace(for: "padding-top", rules: [padding, top])?.ruleID == 2)
    #expect(InspectorCascade.trace(for: "z-index", rules: [padding, top]) == nil)
  }

  @Test func disabledPseudoAndAncestorRulesStayOutOfTheWrongCascade() {
    var disabled = rule(1, "button", order: 2, specificity: (0, 0, 1), color: "white")
    disabled.declarations[0].disabled = true
    let parent = rule(
      4, "main", order: 1, specificity: (0, 0, 1), color: "black", note: "Inherited", distance: 1)
    let grandparent = rule(
      5, "body", order: 1, specificity: (0, 0, 1), color: "red", important: true, note: "Inherited",
      distance: 2)
    let pseudo = rule(
      6, "button::before", order: 9, specificity: (0, 0, 2), color: "green", note: "::before")
    let own = rule(3, "#save", order: 3, specificity: (1, 0, 0), color: "red")
    #expect(
      InspectorCascade.trace(for: "color", rules: [disabled, parent, pseudo])?.ruleID == 4)
    #expect(
      InspectorCascade.trace(for: "color", rules: [parent, grandparent])?.ruleID == 4)
    #expect(InspectorCascade.trace(for: "color", rules: [own, grandparent])?.ruleID == 3)
    #expect(InspectorCascade.trace(for: "padding-top", rules: [parent]) == nil)
  }

  @Test func specificityFollowsTheMatchingSelector() {
    let row: [String: Any] = [
      "matchingSelectors": [1],
      "rule": [
        "selectorList": [
          "selectors": [
            ["text": "input", "specificity": ["a": 0, "b": 1, "c": 1]],
            ["text": "button", "specificity": ["a": 0, "b": 0, "c": 1]],
          ]
        ]
      ],
    ]
    #expect(
      InspectorCascade.specificity(matching: row) == InspectorSpecificity(a: 0, b: 0, c: 1))
    let both: [String: Any] = [
      "matchingSelectors": [0, 1],
      "rule": row["rule"]!,
    ]
    #expect(
      InspectorCascade.specificity(matching: both) == InspectorSpecificity(a: 0, b: 1, c: 1))
  }

  private func rule(
    _ id: Int, _ selector: String, order: Int, specificity: (Int, Int, Int), color: String,
    origin: InspectorRuleOrigin = .author, important: Bool = false, note: String = "",
    distance: Int = 0, source: String? = nil
  ) -> InspectorRule {
    let value = important ? color + " !important" : color
    return InspectorRule(
      id: id, selector: selector, source: source ?? "style-\(id)",
      declarations: [.init(name: "color", value: value)], origin: origin, note: note,
      specificity: InspectorSpecificity(a: specificity.0, b: specificity.1, c: specificity.2),
      cascadeOrder: order, distance: distance)
  }
}
