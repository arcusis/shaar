// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import BrowserCore
import Foundation
import Testing

@testable import ArcusisBrowser

@Suite struct InspectorPseudoForceTests {
  @Test func pseudoStateAccessibilityLabelsExplainTheAction() {
    #expect(
      BrowserLocalization.format(
        "Force CSS %@ state", table: "Inspector", language: .english,
        arguments: [.string("focus-within")]) == "Force CSS focus-within state")
    #expect(
      BrowserLocalization.format(
        "Force CSS %@ state", table: "Inspector", language: .hebrew,
        arguments: [.string("focus-within")]) == "כפיית מצב CSS \u{2068}focus-within\u{2069}")
  }

  @Test func hoverRuleAppearsOnlyWhileThatStateIsForced() {
    let base = payload([rule("button", color: "black"), rule("#save", color: "red")])
    let on = InspectorPseudoForce.matched(
      base, states: ["hover"], rules: ["hover": rule("button:hover", color: "red")])
    #expect(InspectorPseudoForce.selectors(in: on) == ["button", "#save", "button:hover"])
    let off = InspectorPseudoForce.matched(
      on, states: [], rules: ["hover": rule("button:hover", color: "red")])
    #expect(InspectorPseudoForce.selectors(in: off) == ["button", "#save"])
  }

  @Test func focusDoesNotClaimAFocusVisibleRule() {
    let base = payload([rule("button:focus-visible", color: "blue")])
    let focused = InspectorPseudoForce.matched(
      base, states: ["focus"], rules: ["focus": rule("button:focus", color: "navy")])
    #expect(InspectorPseudoForce.selectors(in: focused) == ["button:focus"])
    #expect(InspectorPseudoForce.state(in: "button:focus-visible") == "focus-visible")
    #expect(InspectorPseudoForce.state(in: "button:focus") == "focus")
  }

  @Test func severalStatesStayInCanonicalOrderAndUnknownNamesDrop() {
    let matched = InspectorPseudoForce.matched(
      payload([rule("button", color: "black")]),
      states: ["focus-within", "nope", "hover", "hover"],
      rules: [
        "hover": rule("button:hover", color: "red"),
        "focus-within": rule("button:focus-within", color: "green"),
        "active": rule("button:active", color: "orange"),
      ])
    #expect(
      InspectorPseudoForce.selectors(in: matched) == [
        "button", "button:hover", "button:focus-within",
      ])
    #expect(InspectorPseudoForce.ordered(["focus", "hover", "target"]) == ["hover", "focus"])
  }

  private func payload(_ rows: [[String: Any]]) -> [String: Any] {
    ["matchedCSSRules": rows]
  }

  private func rule(_ selector: String, color: String) -> [String: Any] {
    [
      "rule": [
        "selectorList": [
          "selectors": [["text": selector]],
          "text": selector,
        ],
        "origin": "regular",
        "style": [
          "cssProperties": [["name": "color", "value": color]]
        ],
      ],
      "matchingSelectors": [0],
    ]
  }
}
