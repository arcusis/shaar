// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation
import JavaScriptCore
import SwiftUI
import Testing

@testable import ArcusisBrowser

@Suite @MainActor struct InspectorDetailsTests {
  @Test func componentSnapshotsValidateIdentityAndRenderFrameworkData() async throws {
    let inspector = try makeInspector(tab: .component)
    defer { inspector.close() }
    let model = inspector.details
    for framework in ["React", "Vue", "Svelte"] {
      let tree = tree(framework)
      let data = InspectorComponentData(
        id: 1, name: "Counter", source: "/src/Counter.swift:12", props: "{\"label\":\"Count\"}",
        state: "{\"count\":2}", hooks: framework == "React" ? "[{\"slot\":0,\"value\":2}]" : "null",
        truncated: false, note: framework == "Svelte" ? "Development registration snapshot" : nil)
      try model.receive(
        .component(tree, data), selectionID: 8, generation: inspector.documentGeneration)
      #expect(model.tree?.framework == framework && model.selectedComponent == 1)
      for scheme in [ColorScheme.light, .dark] {
        #expect(
          try await InspectorPanelTests.render(InspectorPanel(model: inspector), scheme: scheme)
            .count > 4_096)
      }
    }
    let wrong = InspectorComponentData(
      id: 9, name: "Wrong owner", source: nil, props: "null", state: "null", hooks: "null",
      truncated: false, note: nil)
    #expect(throws: InspectorFailure.self) {
      try model.receive(
        .component(tree("React"), wrong), selectionID: 8, generation: inspector.documentGeneration)
    }
    let duplicate = InspectorComponentTree(
      framework: "React",
      nodes: [
        .init(id: 1, name: "One", parent: nil, source: nil),
        .init(id: 1, name: "Two", parent: nil, source: nil),
      ], selected: 1, limit: nil)
    #expect(throws: InspectorFailure.self) {
      try model.receive(
        .component(duplicate, nil), selectionID: 8, generation: inspector.documentGeneration)
    }
    try model.receive(
      .component(.init(framework: nil, nodes: [], selected: nil, limit: nil), nil), selectionID: 8,
      generation: inspector.documentGeneration)
    #expect(
      try await InspectorPanelTests.render(InspectorPanel(model: inspector), scheme: .light).count
        > 4_096)
  }

  @Test func accessibilityAndAssetPanelsRenderWithoutAPlatformEngine() async throws {
    let inspector = try makeInspector(tab: .accessibility)
    defer { inspector.close() }
    let model = inspector.details
    var accessibility = InspectorAccessibilityData(
      aria: [.init(name: "aria-label", value: "Save")], tabOrder: 2, tabLimit: true,
      warnings: ["Computed contrast is below WCAG AA."])
    accessibility.role = "button"
    accessibility.name = "Save"
    accessibility.ignored = false
    accessibility.properties = [.init(name: "focusable", value: "true")]
    try model.receive(
      .accessibility(accessibility), selectionID: 8, generation: inspector.documentGeneration)
    for scheme in [ColorScheme.light, .dark] {
      #expect(
        try await InspectorPanelTests.render(InspectorPanel(model: inspector), scheme: scheme).count
          > 4_096)
    }
    inspector.tab = .assets
    var assets = InspectorAssetsData(
      images: [
        .init(
          index: 0, url: "https://example.com/art.png", renderedWidth: 128, renderedHeight: 96,
          naturalWidth: 64, naturalHeight: 48, transferSize: 768, bodySize: 512, mime: "image/png",
          frameID: "frame")
      ], svg: "<svg viewBox='0 0 10 10'></svg>", svgTruncated: false)
    assets.fonts = [
      .init(url: "https://example.com/font.woff2", mime: "font/woff2", frameID: "frame")
    ]
    try model.receive(.assets(assets), selectionID: 8, generation: inspector.documentGeneration)
    for scheme in [ColorScheme.light, .dark] {
      #expect(
        try await InspectorPanelTests.render(InspectorPanel(model: inspector), scheme: scheme).count
          > 4_096)
    }
    let generation = inspector.documentGeneration
    inspector.documentChanged(url: inspector.target.url, committed: true)
    #expect(throws: CancellationError.self) {
      try model.receive(.assets(assets), selectionID: 8, generation: generation)
    }
    #expect(model.assets == nil && model.tree == nil && model.accessibility == nil)
  }

  @Test func unavailableEngineRefreshReportsFailureAndKeepsValidatedDetails() async throws {
    for tab in [InspectorModel.Tab.component, .accessibility, .assets] {
      let inspector = try makeInspector(tab: tab)
      let model = inspector.details
      switch tab {
      case .component:
        try model.receive(
          .component(tree("React"), nil), selectionID: 8, generation: inspector.documentGeneration)
      case .accessibility:
        try model.receive(
          .accessibility(.init(aria: [], tabOrder: nil, tabLimit: false, warnings: [])),
          selectionID: 8, generation: inspector.documentGeneration)
      case .assets:
        try model.receive(
          .assets(.init(images: [], svg: nil, svgTruncated: false)), selectionID: 8,
          generation: inspector.documentGeneration)
      default: Issue.record("Unexpected detail tab")
      }
      await model.refresh(force: true)
      #expect(model.failure != nil && !model.busy)
      #expect(model.selectedID == 8 && model.activeTab == tab)
      switch tab {
      case .component: #expect(model.tree?.framework == "React")
      case .accessibility: #expect(model.accessibility != nil)
      case .assets: #expect(model.assets?.images.isEmpty == true)
      default: break
      }
      inspector.close()
    }
  }

  @Test func malformedAssetDimensionsAndOversizedPayloadsAreRejected() throws {
    let inspector = try makeInspector(tab: .assets)
    defer { inspector.close() }
    let image = InspectorAssetsData.Image(
      index: 0, url: "https://example.com/a.png", renderedWidth: .nan, renderedHeight: 10,
      naturalWidth: 10, naturalHeight: 10, transferSize: nil, bodySize: nil)
    #expect(!image.valid)
    #expect(throws: InspectorFailure.self) {
      try inspector.details.receive(
        .assets(.init(images: [image], svg: nil, svgTruncated: false)), selectionID: 8,
        generation: inspector.documentGeneration)
    }
    let svg = String(repeating: "x", count: 262_145)
    #expect(throws: InspectorFailure.self) {
      try inspector.details.receive(
        .assets(.init(images: [], svg: svg, svgTruncated: true)), selectionID: 8,
        generation: inspector.documentGeneration)
    }
  }

  @Test func shippingDetailsScriptParsesAsJavaScript() throws {
    let context = try #require(JSContext())
    #expect(
      context.evaluateScript("source => { new Function(source); return true; }")?.call(
        withArguments: [InspectorDetailsScript.install])?.toBool() == true)
    #expect(context.exception == nil)
  }

  private func makeInspector(tab: InspectorModel.Tab) throws -> InspectorModel {
    let inspector = InspectorModel(
      target: .init(tabID: UUID(), profileID: UUID(), url: URL(string: "https://example.com")!),
      engine: nil)
    inspector.open()
    inspector.tab = tab
    try inspector.receive(InspectorPanelTests.fixtureSelection())
    return inspector
  }

  private func tree(_ framework: String) -> InspectorComponentTree {
    .init(
      framework: framework,
      nodes: [
        .init(id: 1, name: "Counter", parent: nil, source: "Counter.jsx:12"),
        .init(id: 2, name: "Label", parent: 1, source: nil),
      ], selected: 1, limit: "Snapshot bounded to 250 components")
  }
}
