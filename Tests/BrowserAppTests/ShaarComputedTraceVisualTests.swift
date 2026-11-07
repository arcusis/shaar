// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarComputedTraceVisualTests: XCTestCase {
  func testComputedWinnerRendersOffscreen() throws {
    let phase = ProcessInfo.processInfo.environment["SHAAR_COMPUTED_CAPTURE"] ?? ""
    guard phase == "before" || phase == "after" else {
      throw XCTSkip("Offscreen computed capture requires SHAAR_COMPUTED_CAPTURE=before or after")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1270")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let inspector = InspectorModel(
      target: .init(
        tabID: UUID(), profileID: UUID(), url: URL(string: "http://127.0.0.1/inspector")!),
      engine: nil)
    inspector.open()
    defer { inspector.close() }
    inspector.tab = .styles
    try inspector.receive(InspectorPanelTests.fixtureSelection())
    try inspector.styles.receive(
      rules: matchedRules, computed: computed, selectionID: 8,
      generation: inspector.documentGeneration)
    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      let panel = InspectorPanel(model: inspector)
        .frame(width: 320, height: 1680)
        .environment(\.colorScheme, scheme)
      let image = try VisualCapture.renderOffscreen(
        panel, size: NSSize(width: 320, height: 1680), appearance: appearance,
        to: root.appending(path: "\(phase)-computed-\(suffix).png"))
      XCTAssertEqual(image.pixelsWide, 320)
      XCTAssertEqual(image.pixelsHigh, 1680)
    }
    XCTAssertTrue(NSApp.keyWindow === previous)
  }

  private var matchedRules: [InspectorRule] {
    [
      InspectorRule(
        id: 1, selector: "button", source: "http://127.0.0.1/inspector#style-1:4",
        declarations: [
          .init(name: "padding", value: "10px 20px"),
          .init(name: "color", value: "white"),
          .init(name: "background-color", value: "rgb(37, 99, 235)"),
        ],
        origin: .author, editable: true, matchText: "padding: 10px 20px; color: white;",
        specificity: InspectorSpecificity(a: 0, b: 0, c: 1), cascadeOrder: 1),
      InspectorRule(
        id: 2, selector: "button", source: "http://127.0.0.1/inspector#style-2:1",
        declarations: [.init(name: "color", value: "blue !important")],
        origin: .author, editable: true, matchText: "color: blue !important;",
        specificity: InspectorSpecificity(a: 0, b: 0, c: 1), cascadeOrder: 2),
      InspectorRule(
        id: 3, selector: "#save", source: "http://127.0.0.1/inspector#style-3:1",
        declarations: [.init(name: "color", value: "red")],
        origin: .author, editable: true, matchText: "color: red;",
        specificity: InspectorSpecificity(a: 1, b: 0, c: 0), cascadeOrder: 3),
      InspectorRule(
        id: 4, selector: "main", source: "http://127.0.0.1/inspector#style-1:2",
        declarations: [.init(name: "color", value: "rgb(17, 24, 39)")],
        origin: .author, editable: false, matchText: "color: rgb(17, 24, 39);", note: "Inherited",
        distance: 1),
    ]
  }

  private var computed: [InspectorDeclaration] {
    [
      .init(name: "background-color", value: "rgb(37, 99, 235)"),
      .init(name: "color", value: "rgb(0, 0, 255)"),
      .init(name: "display", value: "inline-block"),
      .init(name: "padding-top", value: "10px"),
    ]
  }
}
