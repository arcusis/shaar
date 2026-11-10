// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import XCTest

@testable import ArcusisBrowser

final class ShaarA11yOverlayTests: XCTestCase {
  func testFocusOrderPutsPositiveTabIndexBeforeDocumentOrder() {
    let stops = [
      stop(id: 1, tabIndex: 0, order: 0, name: "First"),
      stop(id: 2, tabIndex: 2, order: 1, name: "Later"),
      stop(id: 3, tabIndex: -1, order: 2, name: "Skipped"),
      stop(id: 4, tabIndex: 1, order: 3, name: "Priority"),
      stop(id: 5, tabIndex: 0, order: 4, name: "Second"),
    ]
    let names = ShaarFocusOrder.ordered(stops).map(\.name)
    XCTAssertEqual(names, ["Priority", "Later", "First", "Second"])
  }

  func testGrayOnWhiteFailsAndLargeTextPasses() {
    let gray = style(color: "rgb(119, 119, 119)", size: "16px", weight: "400")
    let large = style(color: "rgb(119, 119, 119)", size: "24px", weight: "400")
    let ink = style(color: "rgb(17, 17, 17)", size: "16px", weight: "400")
    let white = ["backgroundColors": ["rgb(255, 255, 255)"]]
    let normal = ShaarA11yContrast.decide(style: gray, colors: white)
    let big = ShaarA11yContrast.decide(style: large, colors: white)
    let strong = ShaarA11yContrast.decide(style: ink, colors: white)
    XCTAssertEqual(normal?.fails, true)
    XCTAssertEqual(normal?.largeText, false)
    XCTAssertGreaterThan(normal?.ratio ?? 0, 4)
    XCTAssertLessThan(normal?.ratio ?? 0, 4.5)
    XCTAssertEqual(big?.fails, false)
    XCTAssertEqual(big?.largeText, true)
    XCTAssertEqual(strong?.fails, false)
  }

  func testGradientAndTranslucentBackgroundsAreNotScored() {
    let gray = style(color: "rgb(119, 119, 119)", size: "16px", weight: "400")
    XCTAssertNil(ShaarA11yContrast.decide(style: gray, colors: ["backgroundColors": []]))
    XCTAssertNil(
      ShaarA11yContrast.decide(style: gray, colors: ["backgroundColors": ["linear-gradient(white, black)"]])
    )
    let composite = ShaarA11yContrast.decide(
      style: gray,
      colors: ["backgroundColors": ["rgba(255, 255, 255, 0.5)", "rgb(0, 0, 0)"]])
    XCTAssertNotNil(composite)
  }

  func testDOMWalkFindsFocusAndContrastMarkers() {
    let root: [String: Any] = [
      "nodeId": 1,
      "children": [
        ["nodeId": 2, "attributes": ["data-shaar-focus", "4"]],
        [
          "nodeId": 3,
          "shadowRoots": [
            [
              "nodeId": 4,
              "attributes": ["data-shaar-contrast", "9", "class", "card"],
            ]
          ],
        ],
      ],
    ]
    let index = ShaarA11yDOMIndex.walk(root)
    XCTAssertEqual(index.focus[4], 2)
    XCTAssertEqual(index.contrast[9], 4)
  }

  func testInventoryDecodesBridgedPageListing() throws {
    let payload: Any = [
      "scrollX": 0, "scrollY": 3, "truncated": true,
      "stops": [
        ["id": 1, "tabIndex": 1, "documentOrder": 0, "name": "Priority", "x": 8, "y": 12]
      ],
      "texts": [
        ["id": 1, "snippet": "Low contrast", "x": 8, "y": 40]
      ],
    ]
    let decoded = ShaarA11yInventoryDecoder.decode(payload)
    XCTAssertEqual(decoded?.stops.first?.name, "Priority")
    XCTAssertEqual(decoded?.stops.first?.tabIndex, 1)
    XCTAssertEqual(decoded?.texts.first?.snippet, "Low contrast")
    XCTAssertEqual(decoded?.truncated, true)
    let data = try JSONSerialization.data(withJSONObject: payload)
    let json = try JSONSerialization.jsonObject(with: data)
    let fromJSON = ShaarA11yInventoryDecoder.decode(json)
    XCTAssertEqual(fromJSON?.scrollY, 3)
    XCTAssertEqual(fromJSON?.stops.first?.documentOrder, 0)
    XCTAssertEqual(fromJSON?.texts.first?.origin, ShaarA11yPoint(x: 8, y: 40))
  }

  func testBoxModelOriginSubtractsScroll() {
    let model: [String: Any] = [
      "model": ["border": [30, 50, 80, 50, 80, 70, 30, 70]]
    ]
    let origin = ShaarA11yBox.viewportOrigin(model, scrollX: 10, scrollY: 20)
    XCTAssertEqual(origin, ShaarA11yPoint(x: 20, y: 30))
  }

  @MainActor func testRefreshPaintsNumberedStopsAndFailingContrast() async {
    let caller = ShaarA11yFixtureCaller()
    let model = ShaarA11yOverlayModel()
    model.setEnabled(true, caller: caller)
    for _ in 0..<80 where model.badges.isEmpty && model.failure == nil {
      try? await Task.sleep(for: .milliseconds(15))
    }
    let decision = ShaarA11yContrast.decide(
      style: style(color: "rgb(119, 119, 119)", size: "16px", weight: "400"),
      colors: ["backgroundColors": ["rgb(255, 255, 255)"]])
    XCTAssertNil(model.failure)
    XCTAssertEqual(
      model.badges.map(\.kind),
      [
        .focus(1), .focus(2),
        .contrast(ShaarA11yContrast.ratioText(decision?.ratio ?? 0)),
      ])
    XCTAssertEqual(model.badges.map(\.snippet), ["Priority control", "First", "Low contrast"])
    XCTAssertTrue(caller.methods.contains("DOM.getBoxModel"))
    XCTAssertTrue(caller.methods.contains("CSS.getBackgroundColors"))
    XCTAssertTrue(caller.methods.contains("Accessibility.getPartialAXTree"))
    XCTAssertTrue(caller.methods.contains("CSS.getComputedStyleForNode"))
    XCTAssertEqual(model.trace.boxModel, true)
    XCTAssertEqual(model.trace.backgroundColors, true)
    XCTAssertEqual(model.trace.partialAXTree, true)
    XCTAssertTrue(model.summary.contains("2 tab stops"))
    XCTAssertTrue(model.summary.contains("1 contrast failure"))
    XCTAssertFalse(model.summary.contains("failures"))
    model.stop(caller)
  }
}

@MainActor private final class ShaarA11yFixtureCaller: ShaarA11yCalling {
  private(set) var methods: [String] = []

  func evaluate(_ expression: String) async throws -> Any? {
    if expression.contains("__shaarA11yOverlay.paint")
      || expression.contains("__shaarA11yOverlay.clear")
    {
      return true
    }
    return [
      "scrollX": 0, "scrollY": 0, "truncated": false,
      "stops": [
        ["id": 1, "tabIndex": 1, "documentOrder": 0, "name": "Priority", "x": 8, "y": 12],
        ["id": 2, "tabIndex": 0, "documentOrder": 1, "name": "First", "x": 40, "y": 12],
        ["id": 3, "tabIndex": -1, "documentOrder": 2, "name": "Minus", "x": 80, "y": 12],
      ],
      "texts": [
        ["id": 1, "snippet": "Low contrast", "x": 8, "y": 40],
        ["id": 2, "snippet": "High contrast", "x": 8, "y": 70],
      ],
    ]
  }

  func call(_ method: String, params: [String: Any]) async throws -> [String: Any] {
    methods.append(method)
    switch method {
    case "DOM.getDocument":
      return ["root": document]
    case "DOM.getBoxModel":
      return ["model": ["border": [8, 12, 40, 12, 40, 28, 8, 28]]]
    case "CSS.getComputedStyleForNode":
      let nodeID = params["nodeId"] as? Int
      if nodeID == 5 {
        return style(color: "rgb(17, 17, 17)", size: "16px", weight: "400")
      }
      return style(color: "rgb(119, 119, 119)", size: "16px", weight: "400")
    case "CSS.getBackgroundColors":
      return ["backgroundColors": ["rgb(255, 255, 255)"]]
    case "Accessibility.getPartialAXTree":
      let nodeID = params["nodeId"] as? Int
      guard nodeID == 2 else { return ["nodes": []] }
      return ["nodes": [["name": ["value": "Priority control"]]]]
    default:
      return [:]
    }
  }

  private var document: [String: Any] {
    [
      "nodeId": 1,
      "children": [
        ["nodeId": 2, "attributes": ["data-shaar-focus", "1"]],
        ["nodeId": 3, "attributes": ["data-shaar-focus", "2"]],
        ["nodeId": 4, "attributes": ["data-shaar-contrast", "1"]],
        ["nodeId": 5, "attributes": ["data-shaar-contrast", "2"]],
      ],
    ]
  }
}

private func stop(id: Int, tabIndex: Int, order: Int, name: String) -> ShaarFocusStop {
  ShaarFocusStop(
    id: id, tabIndex: tabIndex, documentOrder: order, name: name,
    origin: ShaarA11yPoint(x: 0, y: 0))
}

private func style(color: String, size: String, weight: String) -> [String: Any] {
  [
    "computedStyle": [
      ["name": "color", "value": color],
      ["name": "font-size", "value": size],
      ["name": "font-weight", "value": weight],
    ]
  ]
}
