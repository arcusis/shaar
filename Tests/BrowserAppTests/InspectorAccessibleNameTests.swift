// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Testing

@testable import ArcusisBrowser

@Suite struct InspectorAccessibleNameTests {
  @Test func headingTextAndAriaLabelAreDifferentSources() {
    let heading: [String: Any] = [
      "type": "computedString",
      "value": "Inspect the details.",
      "sources": [
        ["type": "relatedElement", "attribute": "aria-labelledby"],
        ["type": "attribute", "attribute": "aria-label"],
        contributed(["type": "contents"], "Inspect the details."),
        ["type": "attribute", "attribute": "title", "superseded": true],
      ],
    ]
    let button: [String: Any] = [
      "type": "computedString",
      "value": "Apply the form",
      "sources": [
        ["type": "relatedElement", "attribute": "aria-labelledby"],
        contributed(["type": "attribute", "attribute": "aria-label"], "Apply the form"),
        contributed(["type": "contents", "superseded": true], "Apply"),
      ],
    ]
    #expect(InspectorAccessibleName.source(of: heading) == "From the element's text")
    #expect(InspectorAccessibleName.source(of: button) == "From aria-label")
    #expect(
      InspectorAccessibleName.source(of: heading) != InspectorAccessibleName.source(of: button))
  }

  @Test func labelledByAndLabelReferencesStayDistinct() {
    let labelledBy: [String: Any] = [
      "value": "Save changes",
      "sources": [
        ["type": "attribute", "attribute": "aria-label"],
        contributed(
          ["type": "relatedElement", "attribute": "aria-labelledby"], "Save changes"),
      ],
    ]
    let label: [String: Any] = [
      "value": "Email",
      "sources": [
        contributed(["type": "relatedElement", "nativeSource": "labelfor"], "Email")
      ],
    ]
    #expect(InspectorAccessibleName.source(of: labelledBy) == "From aria-labelledby")
    #expect(InspectorAccessibleName.source(of: label) == "From a label")
  }

  @Test func aMissingNameHasNoSource() {
    #expect(InspectorAccessibleName.source(of: nil) == nil)
    #expect(InspectorAccessibleName.source(of: ["value": ""]) == nil)
    #expect(
      InspectorAccessibleName.source(of: [
        "value": "   ",
        "sources": [contributed(["type": "contents"], "   ")],
      ]) == nil)
    let invalid: [String: Any] = [
      "value": "Name",
      "sources": [
        contributed(
          ["type": "attribute", "attribute": "aria-label", "invalid": true], "Name")
      ],
    ]
    let unused: [String: Any] = [
      "value": "Inspect the details.",
      "sources": [
        ["type": "relatedElement", "attribute": "aria-labelledby"],
        ["type": "attribute", "attribute": "aria-label"],
      ],
    ]
    #expect(InspectorAccessibleName.source(of: invalid) == nil)
    #expect(InspectorAccessibleName.source(of: unused) == nil)
  }
}

private func contributed(_ fields: [String: Any], _ text: String) -> [String: Any] {
  var source = fields
  source["value"] = ["type": "computedString", "value": text]
  return source
}
