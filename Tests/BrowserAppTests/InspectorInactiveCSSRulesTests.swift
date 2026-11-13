// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
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

  private func embeddedProperties(in expression: String) throws -> [String]? {
    let start = try #require(expression.range(of: ")(", options: .backwards))
    let suffix = expression[start.upperBound...]
    let end = try #require(suffix.range(of: "])", options: .backwards))
    let encoded = String(suffix[..<end.lowerBound]) + "]"
    return try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String]
  }
}
