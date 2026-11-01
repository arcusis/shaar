// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import JavaScriptCore
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct InspectorStylesTests {
  @Test func authoredDeclarationsPreserveFallbacksAndExcludeExpandedShorthands() {
    let inspector = makeInspector()
    let rows = inspector.styles.declarations([
      "styleSheetId": "sheet",
      "cssProperties": [
        ["name": "display", "value": "block", "text": "display:block"],
        ["name": "display", "value": "grid", "text": "display:grid", "important": true],
        ["name": "padding-top", "value": "4px", "implicit": true, "text": "padding-top:4px"],
        ["name": "color", "value": "red", "disabled": true, "text": "color:red"],
        ["name": "margin-top", "value": "4px"],
      ],
    ])
    #expect(rows.map(\.name) == ["display", "display"])
    #expect(rows.map(\.value) == ["block", "grid !important"])
    #expect(Set(rows.map(\.id)).count == 2)
  }

  @Test func layoutAndExportsUseCurrentValidatedSnapshot() async throws {
    let inspector = makeInspector()
    inspector.open()
    defer { inspector.close() }
    try inspector.receive(InspectorPanelTests.fixtureSelection())
    let model = inspector.styles
    let generation = inspector.documentGeneration
    try model.receive(rules: [], computed: computed("grid"), selectionID: 8, generation: generation)
    #expect(model.canOverlay)
    #expect(model.layout.contains { $0.name == "grid-template-columns" })
    #expect(!model.layout.contains { $0.name == "flex-direction" })
    #expect(model.css.contains(".save {\n"))
    #expect(model.css.contains("grid-template-columns: 1fr 2fr;"))
    #expect(model.tailwind.contains("[grid-template-columns:1fr_2fr]"))
    #expect(model.tailwind.contains(#"[font-family:Font\_Name,_sans-serif]"#))
    #expect(Set(model.exported.map(\.name)).count == model.exported.count)
    let oversized = [
      InspectorDeclaration(name: "color", value: String(repeating: "x", count: 4111))
    ]
    #expect(throws: InspectorFailure.self) {
      try model.receive(rules: [], computed: oversized, selectionID: 8, generation: generation)
    }
    #expect(model.computed == computed("grid"))
    inspector.documentChanged(url: inspector.target.url, committed: true)
    #expect(throws: CancellationError.self) {
      try model.receive(
        rules: [], computed: computed("grid"), selectionID: 8, generation: generation)
    }
    #expect(model.rules.isEmpty && model.computed.isEmpty && model.selectedID == nil)
    await #expect(throws: InspectorFailure.self) { _ = try await model.screenshot() }
  }

  @Test func nativeCSSPanelRendersGridFlexAndSourceLimitStates() async throws {
    let inspector = makeInspector()
    inspector.open()
    defer { inspector.close() }
    inspector.tab = .styles
    try inspector.receive(InspectorPanelTests.fixtureSelection())
    for display in ["grid", "flex"] {
      let rules = [
        InspectorRule(
          id: 0, selector: ".save", source: "https://example.com/main.css:12",
          declarations: [
            .init(name: "display", value: display), .init(name: "gap", value: "12px !important"),
          ]),
        InspectorRule(
          id: 1, selector: "button", source: "Stylesheet unavailable:24",
          declarations: [.init(name: "border", value: "1px solid")]),
      ]
      try inspector.styles.receive(
        rules: rules, computed: computed(display), selectionID: 8,
        generation: inspector.documentGeneration)
      #expect(
        inspector.styles.layout.contains {
          $0.name == (display == "grid" ? "grid-template-columns" : "flex-direction")
        })
      for scheme in [ColorScheme.light, .dark] {
        #expect(
          try await InspectorPanelTests.render(InspectorPanel(model: inspector), scheme: scheme)
            .count > 4_096)
      }
    }
  }

  @Test func shippingStyleScriptParsesAsJavaScript() throws {
    let context = try #require(JSContext())
    #expect(
      context.evaluateScript("source => { new Function(source); return true; }")?.call(
        withArguments: [InspectorStyleScript.install])?.toBool() == true)
    #expect(context.exception == nil)
  }

  private func makeInspector() -> InspectorModel {
    InspectorModel(
      target: .init(tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com")!),
      engine: nil)
  }

  private func computed(_ display: String) -> [InspectorDeclaration] {
    [
      ("display", display), ("position", "relative"), ("box-sizing", "border-box"),
      ("grid-template-columns", "1fr 2fr"), ("flex-direction", "row"), ("align-items", "center"),
      ("row-gap", "12px"), ("column-gap", "12px"), ("font-family", "Font_Name, sans-serif"),
      ("color", "rgb(0, 0, 0)"),
    ].map { .init(name: $0.0, value: $0.1) }
  }
}
