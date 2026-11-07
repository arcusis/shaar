// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarStylesRuleVisualTests: XCTestCase {
  func testMatchedRuleEditorRendersOffscreen() throws {
    let phase = ProcessInfo.processInfo.environment["SHAAR_STYLES_CAPTURE"] ?? ""
    guard phase == "before" || phase == "after" else {
      throw XCTSkip("Offscreen styles capture requires SHAAR_STYLES_CAPTURE=before or after")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1269")
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
        .frame(width: 320, height: 1200)
        .environment(\.colorScheme, scheme)
      let image = try VisualCapture.renderOffscreen(
        panel, size: NSSize(width: 320, height: 1200), appearance: appearance,
        to: root.appending(path: "\(phase)-styles-\(suffix).png"))
      XCTAssertEqual(image.pixelsWide, 320)
      XCTAssertEqual(image.pixelsHigh, 1200)
    }
    XCTAssertTrue(NSApp.keyWindow === previous)
  }

  private var matchedRules: [InspectorRule] {
    [
      InspectorRule(
        id: 0, selector: "button", source: "http://127.0.0.1/inspector#style-1:4",
        declarations: [
          .init(name: "padding", value: "10px 20px"),
          .init(name: "color", value: "white", disabled: true),
          .init(name: "outline-offset", value: "4px"),
        ],
        origin: .author, editable: true, matchText: "padding: 10px 20px; outline-offset: 4px;"),
      InspectorRule(
        id: 1, selector: "main", source: "http://127.0.0.1/inspector#style-1:2",
        declarations: [.init(name: "color", value: "rgb(17, 24, 39)")],
        origin: .author, editable: false, matchText: "color: rgb(17, 24, 39);", note: "Inherited"),
      InspectorRule(
        id: 2, selector: "button::before", source: "http://127.0.0.1/inspector#style-1:12",
        declarations: [.init(name: "content", value: "\"\"")],
        origin: .author, editable: true, matchText: "content: \"\";", note: "::before"),
      InspectorRule(
        id: 3, selector: "button", source: "Browser default",
        declarations: [.init(name: "font-style", value: "normal")],
        origin: .userAgent),
    ]
  }

  private var computed: [InspectorDeclaration] {
    [
      .init(name: "display", value: "inline-block"),
      .init(name: "color", value: "rgb(255, 255, 255)"),
      .init(name: "padding-top", value: "10px"),
    ]
  }
}
