// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct ShaarStackingViewTests {
  @Test func absoluteZIndexCreatesAContextAndAutoDoesNot() {
    let positioned = element(4, name: "div#modal", position: "absolute", zIndex: "2")
    let automatic = element(5, name: "div#card", position: "absolute", zIndex: "auto")
    #expect(ShaarStackingContext.reasons(for: positioned, isRoot: false) == ["z-index: 2"])
    #expect(ShaarStackingContext.reasons(for: automatic, isRoot: false).isEmpty)
  }

  @Test func opacityTransformFixedFlexAndPaintPropertiesCreateContexts() {
    #expect(!reasons(opacity: "1").contains { $0.hasPrefix("opacity") })
    #expect(reasons(opacity: "0.5").contains("opacity: 0.5"))
    #expect(reasons(transform: "none").isEmpty)
    #expect(reasons(transform: "matrix(1, 0, 0, 1, 0, 0)") == ["transform"])
    #expect(reasons(position: "fixed", zIndex: "auto") == ["position: fixed"])
    #expect(reasons(position: "static", zIndex: "4").isEmpty)
    let flexItem = element(6, name: "div", zIndex: "1", parentDisplay: "flex")
    let flexAuto = element(7, name: "div", zIndex: "auto", parentDisplay: "inline-flex")
    #expect(ShaarStackingContext.reasons(for: flexItem, isRoot: false) == ["flex item z-index"])
    #expect(ShaarStackingContext.reasons(for: flexAuto, isRoot: false).isEmpty)
    #expect(reasons(isolation: "isolate") == ["isolation"])
    #expect(reasons(willChange: "transform") == ["will-change"])
    #expect(reasons(contain: "paint") == ["contain"])
    #expect(reasons(contain: "layout").isEmpty)
    #expect(reasons(filter: "blur(1px)") == ["filter"])
    #expect(reasons(mixBlendMode: "multiply") == ["mix-blend-mode"])
  }

  @Test func zIndexModeLiftsContextsRelativeToTheParent() throws {
    let slabs = ShaarStackingLayout.slabs(from: page(), mode: .zIndex)
    let level = Dictionary(uniqueKeysWithValues: slabs.map { ($0.name, $0.level) })
    #expect(level["html"] == 0)
    #expect(level["div#behind"] == -ShaarStackingLayout.zStep)
    #expect(level["div#modal"] == 10 * ShaarStackingLayout.zStep)
    let behind = try #require(level["div#behind"])
    let faded = try #require(level["div#faded"])
    let modal = try #require(level["div#modal"])
    #expect(behind < faded)
    #expect(faded < modal)
    #expect(slabs.first { $0.name == "div#card" }?.createsContext == false)
    #expect(slabs.first { $0.name == "div#modal" }?.createsContext == true)
  }

  @Test func domModeSeparatesElementsByDepth() {
    let slabs = ShaarStackingLayout.slabs(from: page(), mode: .dom)
    let modal = slabs.first { $0.name == "div#modal" }
    let card = slabs.first { $0.name == "div#card" }
    #expect(modal?.level == Double(modal?.depth ?? 0) * ShaarStackingLayout.domStep)
    #expect(card?.depth == modal?.depth)
    #expect(card?.level == modal?.level)
  }

  @Test func zeroSizeElementsAreOmitted() {
    let hidden = element(3, name: "div#gone", bounds: CGRect(x: 0, y: 0, width: 0, height: 10))
    let shown = element(4, name: "div#shown", bounds: CGRect(x: 0, y: 0, width: 20, height: 10))
    let slabs = ShaarStackingLayout.slabs(from: [hidden, shown], mode: .dom)
    #expect(slabs.map(\.name) == ["div#shown"])
  }

  @Test func hitTestingPicksTheHigherSlab() {
    let root = element(
      1, name: "html", bounds: CGRect(x: 0, y: 0, width: 200, height: 200), depth: 0)
    let child = element(
      2, name: "div#modal", parentID: 1, bounds: CGRect(x: 20, y: 20, width: 40, height: 40),
      depth: 1, position: "absolute", zIndex: "3")
    let model = ShaarStackingModel()
    model.present(ShaarStackingSnapshot(elements: [root, child], clipped: false), mode: .dom)
    model.camera = ShaarStackingCamera(yaw: 0, pitch: 0, zoom: 1, panX: 0, panY: 0)
    model.hit(CGPoint(x: 30, y: 30))
    #expect(model.selectedID == 2)
    #expect(model.highlightedID == 2)
    model.hit(CGPoint(x: 10, y: 10))
    #expect(model.selectedID == 1)
    model.hit(CGPoint(x: 400, y: 400))
    #expect(model.selectedID == 1)
  }

  @Test func fittedCameraKeepsSlabsInsideTheView() {
    let slabs = ShaarStackingLayout.slabs(from: page(), mode: .zIndex)
    let size = CGSize(width: 640, height: 420)
    let camera = ShaarStackingProjection.fitted(slabs: slabs, in: size, orbit: .orbit)
    for slab in slabs {
      for corner in ShaarStackingProjection.quad(
        bounds: slab.bounds, level: slab.level, camera: camera)
      {
        #expect(corner.x >= -0.5 && corner.x <= size.width + 0.5)
        #expect(corner.y >= -0.5 && corner.y <= size.height + 0.5)
      }
    }
  }

  @Test func captureParserReadsBoxModelAndComputedStyle() {
    let document: [String: Any] = [
      "root": [
        "nodeId": 1, "nodeType": 9, "nodeName": "#document",
        "children": [
          [
            "nodeId": 2, "nodeType": 1, "nodeName": "HTML",
            "children": [
              [
                "nodeId": 3, "nodeType": 1, "nodeName": "HEAD",
                "children": [
                  ["nodeId": 4, "nodeType": 1, "nodeName": "STYLE"]
                ],
              ],
              [
                "nodeId": 5, "nodeType": 1, "nodeName": "BODY",
                "children": [
                  [
                    "nodeId": 6, "nodeType": 1, "nodeName": "DIV", "backendNodeId": 60,
                    "attributes": ["id", "modal", "class", "panel open"],
                  ]
                ],
              ],
            ],
          ]
        ],
      ]
    ]
    let elements = ShaarStackingCapture.elements(
      from: document,
      boxes: [
        2: box(0, 0, 800, 600),
        5: box(0, 0, 800, 600),
        6: box(40, 50, 180, 120),
      ],
      styles: [
        2: style(["display": "block", "position": "static"]),
        5: style(["display": "block", "position": "static"]),
        6: style([
          "display": "block", "position": "absolute", "z-index": "10", "opacity": "1",
        ]),
      ])
    let names = elements.map(\.name)
    #expect(names == ["html", "body", "div#modal.panel.open"])
    let modal = elements[2]
    #expect(modal.parentDisplay == "block")
    #expect(modal.backendNodeID == 60)
    #expect(modal.bounds == CGRect(x: 40, y: 50, width: 180, height: 120))
    let slabs = ShaarStackingLayout.slabs(from: elements, mode: .zIndex)
    #expect(slabs.first { $0.nodeID == 6 }?.zIndex == 10)
    #expect(slabs.first { $0.nodeID == 6 }?.createsContext == true)
  }

  @Test func captureKeepsTheFirstElementsAndMarksTheRestClipped() {
    var children: [[String: Any]] = []
    for nodeID in 3...202 {
      children.append(["nodeId": nodeID, "nodeType": 1, "nodeName": "DIV"])
    }
    let document: [String: Any] = [
      "root": [
        "nodeId": 1, "nodeType": 9, "nodeName": "#document",
        "children": [
          [
            "nodeId": 2, "nodeType": 1, "nodeName": "HTML",
            "children": children,
          ]
        ],
      ]
    ]
    let elements = ShaarStackingCapture.elements(from: document, boxes: [:], styles: [:])
    #expect(elements.count == ShaarStackingLayout.maximumNodes)
    #expect(elements.first?.name == "html")
  }

  @Test func selectingASlabSelectsAndHighlightsTheElement() async throws {
    let transport = DOMFixtureTransport()
    let defaults = UserDefaults(suiteName: "ShaarStacking.\(UUID().uuidString)")!
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://127.0.0.1/")!)
    let shell = ShaarDevToolsModel(
      target: target, domTransport: transport, layoutDefaults: defaults)
    let inspector = InspectorModel(target: target, engine: nil)
    shell.open(inspector: inspector)
    shell.section = .stacking
    let loaded = await waitUntil { shell.dom.nodes[4] != nil }
    let modal = element(
      4, name: "main#app", bounds: CGRect(x: 8, y: 8, width: 40, height: 20), depth: 3,
      position: "absolute", zIndex: "10")
    shell.stacking.present(ShaarStackingSnapshot(elements: [modal], clipped: false))
    shell.stacking.select(4)
    let highlighted = await waitUntil { shell.stacking.highlightedID == 4 }
    #expect(loaded)
    #expect(highlighted)
    #expect(shell.dom.selectedID == 4)
    #expect(
      shell.dom.selected?.attributes.contains { $0.name == "id" && $0.value == "app" } == true)
    #expect(transport.commands.contains(.highlight(4)))
    shell.section = .elements
    #expect(shell.dom.selectedID == 4)
    shell.close()
    inspector.close()
  }

  @Test func selectingASlabRebindsAfterFrontendIdsAreDropped() async throws {
    let transport = DOMFixtureTransport()
    transport.documentsByDepth[12] = [
      "root": [
        "nodeId": 10, "nodeType": 9, "nodeName": "#document", "nodeValue": "",
        "children": [
          [
            "nodeId": 11, "nodeType": 1, "nodeName": "HTML", "nodeValue": "",
            "children": [
              [
                "nodeId": 12, "nodeType": 1, "nodeName": "BODY", "nodeValue": "",
                "children": [
                  [
                    "nodeId": 70, "nodeType": 1, "nodeName": "MAIN", "nodeValue": "",
                    "backendNodeId": 900, "attributes": ["id", "app"],
                  ]
                ],
              ]
            ],
          ]
        ],
      ]
    ]
    transport.describedBackends[900] = [
      "nodeId": 70, "nodeType": 1, "nodeName": "MAIN", "nodeValue": "", "backendNodeId": 900,
    ]
    let defaults = UserDefaults(suiteName: "ShaarStacking.\(UUID().uuidString)")!
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://127.0.0.1/")!)
    let shell = ShaarDevToolsModel(
      target: target, domTransport: transport, layoutDefaults: defaults)
    let inspector = InspectorModel(target: target, engine: nil)
    shell.open(inspector: inspector)
    shell.section = .stacking
    let loaded = await waitUntil { shell.dom.nodes[4] != nil }
    let modal = element(
      50, name: "main#app", bounds: CGRect(x: 8, y: 8, width: 40, height: 20), depth: 3,
      position: "absolute", zIndex: "10", backendNodeID: 900)
    shell.stacking.present(ShaarStackingSnapshot(elements: [modal], clipped: false))
    shell.stacking.select(50)
    let highlighted = await waitUntil { shell.stacking.highlightedID == 50 }
    #expect(loaded)
    #expect(highlighted)
    #expect(shell.dom.selectedID == 70)
    #expect(shell.dom.selected?.backendNodeID == 900)
    #expect(transport.commands.contains(.highlight(70)))
    #expect(shell.stacking.failure == nil)
    shell.close()
    inspector.close()
  }
}

private func page() -> [ShaarStackingElement] {
  [
    element(1, name: "html", bounds: CGRect(x: 0, y: 0, width: 800, height: 600), depth: 0),
    element(
      2, name: "body", parentID: 1, bounds: CGRect(x: 0, y: 0, width: 800, height: 600), depth: 1),
    element(
      3, name: "div#page", parentID: 2, bounds: CGRect(x: 0, y: 0, width: 400, height: 300),
      depth: 2, position: "relative", zIndex: "auto"),
    element(
      4, name: "div#behind", parentID: 3, bounds: CGRect(x: 20, y: 20, width: 160, height: 80),
      depth: 3, position: "absolute", zIndex: "-1"),
    element(
      5, name: "div#card", parentID: 3, bounds: CGRect(x: 40, y: 40, width: 200, height: 120),
      depth: 3, position: "absolute", zIndex: "auto"),
    element(
      6, name: "div#modal", parentID: 3, bounds: CGRect(x: 80, y: 70, width: 180, height: 100),
      depth: 3, position: "absolute", zIndex: "10"),
    element(
      7, name: "div#faded", parentID: 3, bounds: CGRect(x: 12, y: 180, width: 100, height: 40),
      depth: 3, opacity: "0.5"),
  ]
}

private func element(
  _ nodeID: Int, name: String, parentID: Int? = nil,
  bounds: CGRect? = CGRect(x: 0, y: 0, width: 80, height: 40), depth: Int = 1,
  position: String = "static", zIndex: String = "auto", opacity: String = "1",
  transform: String = "none", filter: String = "none", isolation: String = "auto",
  willChange: String = "auto", contain: String = "none", mixBlendMode: String = "normal",
  parentDisplay: String = "block", backendNodeID: Int? = nil
) -> ShaarStackingElement {
  ShaarStackingElement(
    nodeID: nodeID, parentID: parentID, name: name, depth: depth, bounds: bounds,
    style: ShaarStackingStyle(
      position: position, zIndex: zIndex, opacity: opacity, transform: transform, filter: filter,
      mixBlendMode: mixBlendMode, isolation: isolation, willChange: willChange, contain: contain,
      display: "block"),
    parentDisplay: parentDisplay, backendNodeID: backendNodeID)
}

private func reasons(
  position: String = "static", zIndex: String = "auto", opacity: String = "1",
  transform: String = "none", filter: String = "none", isolation: String = "auto",
  willChange: String = "auto", contain: String = "none", mixBlendMode: String = "normal"
) -> [String] {
  ShaarStackingContext.reasons(
    for: element(
      9, name: "div", position: position, zIndex: zIndex, opacity: opacity, transform: transform,
      filter: filter, isolation: isolation, willChange: willChange, contain: contain,
      mixBlendMode: mixBlendMode),
    isRoot: false)
}

private func box(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> [String: Any] {
  [
    "model": [
      "border": [x, y, x + width, y, x + width, y + height, x, y + height]
    ]
  ]
}

private func style(_ values: [String: String]) -> [String: Any] {
  ["computedStyle": values.map { ["name": $0.key, "value": $0.value] }]
}

@MainActor private func waitUntil(
  _ ready: @MainActor () -> Bool
) async -> Bool {
  for _ in 0..<40 {
    if ready() { return true }
    try? await Task.sleep(for: .milliseconds(25))
  }
  return ready()
}
