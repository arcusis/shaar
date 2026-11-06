// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct InspectorInactiveCSSViewTests {
  @Test func inactiveDeclarationHintsRenderOffscreenInBothAppearances() async throws {
    let inspector = InspectorModel(
      target: .init(tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com")!),
      engine: nil)
    defer { inspector.close() }
    inspector.open()
    inspector.tab = .styles
    try inspector.receive(InspectorPanelTests.fixtureSelection())
    try inspector.styles.receive(
      rules: [
        .init(
          id: 0, selector: ".save", source: "/fixture.css:1",
          declarations: [
            .init(name: "justify-content", value: "center"),
            .init(name: "flex-direction", value: "row"),
            .init(name: "grid-template-columns", value: "1fr 1fr"),
            .init(name: "top", value: "0"),
            .init(name: "text-overflow", value: "ellipsis"),
            .init(name: "vertical-align", value: "middle"),
          ])
      ],
      computed: [
        .init(name: "display", value: "block"), .init(name: "position", value: "static"),
      ],
      inactiveHints: [
        "justify-content": "Requires a flex or grid container.",
        "flex-direction": "Requires a flex container.",
        "grid-template-columns": "Requires a grid container.",
        "top": "Does not apply to statically positioned elements.",
        "text-overflow": "Requires overflow: hidden and white-space: nowrap.",
        "vertical-align": "Does not apply to block-level boxes.",
      ],
      selectionID: 8, generation: inspector.documentGeneration)
    let directory = URL(filePath: "build/Verification/InspectorInactiveCSS")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for scheme in [ColorScheme.light, .dark] {
      let image = try await InspectorPanelTests.render(
        InspectorPanel(model: inspector), scheme: scheme)
      let suffix = scheme == .dark ? "dark" : "light"
      try image.write(to: directory.appending(path: "css-\(suffix).png"), options: .atomic)
    }
  }
}
