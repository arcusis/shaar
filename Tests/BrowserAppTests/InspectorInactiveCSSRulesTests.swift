// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import JavaScriptCore
import Testing

@testable import ArcusisBrowser

struct InspectorInactiveCSSRulesTests {
  @Test func expressionEmbedsPropertiesAsAJSONArray() throws {
    let properties = ["width", "x\");globalThis.compromised=true;//"]
    let expression = InspectorInactiveCSSRules.expression(properties: properties)
    #expect(!expression.contains("__SHAAR_PROPERTIES__"))
    #expect(try embeddedProperties(in: expression) == properties)
  }

  @Test func emptyPropertyListProducesAnEmptyArray() throws {
    let expression = InspectorInactiveCSSRules.expression(properties: [])
    #expect(try embeddedProperties(in: expression) == [])
  }

  @Test func blockElementReportsInactiveLayoutAndPositionProperties() throws {
    let reasons = try evaluate(
      [
        "justify-content", "gap", "flex-direction", "flex", "grid-template-columns", "grid-row",
        "justify-items", "width", "z-index", "top", "vertical-align", "text-overflow", "float",
      ], display: "block", parentDisplay: "block")

    #expect(reasons["justify-content"] == "Requires a flex or grid container.")
    #expect(reasons["gap"] == "Requires a flex, grid, or multi-column container.")
    #expect(reasons["flex-direction"] == "Requires a flex container.")
    #expect(reasons["flex"] == "Requires a flex item.")
    #expect(reasons["grid-template-columns"] == "Requires a grid container.")
    #expect(reasons["grid-row"] == "Requires a grid item.")
    #expect(reasons["justify-items"] == "Requires a grid container.")
    #expect(reasons["width"] == nil)
    #expect(reasons["z-index"] == "Requires positioning or a flex/grid item.")
    #expect(reasons["top"] == "Does not apply to statically positioned elements.")
    #expect(reasons["vertical-align"] == "Does not apply to block-level boxes.")
    #expect(reasons["text-overflow"] == "Requires overflow: hidden and white-space: nowrap.")
    #expect(reasons["float"] == nil)
  }

  @Test func flexAndGridItemsEnableTheirItemProperties() throws {
    let flex = try evaluate(
      ["flex", "flex-grow", "float", "z-index", "flex-direction"],
      display: "block", parentDisplay: "flex")
    #expect(flex["flex"] == nil)
    #expect(flex["flex-grow"] == nil)
    #expect(flex["float"] == "Does not affect flex or grid items.")
    #expect(flex["z-index"] == nil)
    #expect(flex["flex-direction"] == "Requires a flex container.")

    let grid = try evaluate(
      ["grid-column", "grid-area", "float", "z-index"],
      display: "block", parentDisplay: "grid")
    #expect(grid["grid-column"] == nil)
    #expect(grid["grid-area"] == nil)
    #expect(grid["float"] == "Does not affect flex or grid items.")
    #expect(grid["z-index"] == nil)
  }

  private func evaluate(
    _ properties: [String], display: String, parentDisplay: String
  ) throws -> [String: String] {
    let context = try #require(JSContext())
    context.evaluateScript(
      """
      const pageStyle={display:\"\(display)\",position:\"static\",columnCount:\"auto\",columnWidth:\"auto\",overflowX:\"visible\",whiteSpace:\"normal\"};
      const parentStyle={display:\"\(parentDisplay)\"};
      const parent={};
      const element={localName:\"div\",parentElement:parent,ownerDocument:{defaultView:{getComputedStyle(node){return node===element?pageStyle:parentStyle;}}}};
      globalThis.__shaarInspectorV2={element:()=>element};
      """
    )
    let expression = InspectorInactiveCSSRules.expression(properties: properties)
    let result = try #require(context.evaluateScript("JSON.stringify(\(expression))")?.toString())
    #expect(context.exception == nil)
    return try #require(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: String])
  }

  private func embeddedProperties(in expression: String) throws -> [String]? {
    let start = try #require(expression.range(of: ")(", options: .backwards))
    let suffix = expression[start.upperBound...]
    let end = try #require(suffix.range(of: "])", options: .backwards))
    let encoded = String(suffix[..<end.lowerBound]) + "]"
    return try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String]
  }
}
