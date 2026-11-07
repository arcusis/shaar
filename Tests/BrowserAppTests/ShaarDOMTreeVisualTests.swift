// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import AppKit
import SwiftUI
import XCTest

@testable import ArcusisBrowser

@MainActor final class ShaarDOMTreeVisualTests: XCTestCase {
  func testElementsTreeAndFallbackRenderOffscreen() async throws {
    guard ProcessInfo.processInfo.environment["SHAAR_DOM_TREE_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen DOM capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1179")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/dashboard")!)
    let inspector = InspectorModel(target: target, engine: nil)
    inspector.open()
    try inspector.receive(InspectorPanelTests.fixtureSelection())
    defer { inspector.close() }
    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      let before = InspectorPanel(model: inspector)
        .frame(width: 1040, height: 500).environment(\.colorScheme, scheme)
      try capture(
        before, named: "before-elements-\(suffix)",
        appearance: appearance, root: root)

      let pending = ShaarDevToolsModel(target: target)
      pending.open(inspector: inspector)
      let unavailable = ShaarDevToolsPanel(
        model: pending, inspector: inspector, openChromium: {}
      )
      .frame(width: 1040, height: 500).environment(\.colorScheme, scheme)
      try capture(
        unavailable, named: "after-dom-unavailable-\(suffix)",
        appearance: appearance, root: root)
      pending.close()

      let fixture = DOMFixtureTransport()
      let live = ShaarDevToolsModel(target: target, domTransport: fixture)
      live.open(inspector: inspector)
      for _ in 0..<30 where live.dom.rootID == nil { await Task.yield() }
      XCTAssertTrue(live.dom.available)
      live.dom.select(8)
      await live.dom.toggleExpanded(5)
      let after = ShaarDevToolsPanel(model: live, inspector: inspector, openChromium: {})
        .frame(width: 1040, height: 500).environment(\.colorScheme, scheme)
      try capture(
        after, named: "after-dom-tree-\(suffix)",
        appearance: appearance, root: root)
      live.close()
    }
    XCTAssertTrue(NSApp.keyWindow === previous)
  }

  func testCopyPathTreeRendersOffscreen() async throws {
    guard ProcessInfo.processInfo.environment["SHAAR_DOM_TREE_CAPTURE"] == "1" else {
      throw XCTSkip("Offscreen DOM capture requires explicit opt-in")
    }
    _ = NSApplication.shared
    let previous = NSApp.keyWindow
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appending(path: "Evidence/issue-1274")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = SiteControlTarget(
      tabID: UUID(), profileID: UUID(), url: URL(string: "http://localhost:3000/dashboard")!)
    let inspector = InspectorModel(target: target, engine: nil)
    inspector.open()
    try inspector.receive(InspectorPanelTests.fixtureSelection())
    defer { inspector.close() }
    let fixture = DOMFixtureTransport()
    fixture.document = copyPathDocument()
    for scheme in [ColorScheme.light, .dark] {
      let suffix = scheme == .dark ? "dark" : "light"
      let appearance: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
      let model = ShaarDOMTreeModel(target: target, transport: fixture)
      model.open()
      for _ in 0..<30 where model.rootID == nil { await Task.yield() }
      XCTAssertEqual(model.selector(for: 5), "section:nth-of-type(2)")
      model.select(5)
      let panel = ShaarDevToolsPanel(
        model: ShaarDevToolsModel(target: target, domTransport: fixture),
        inspector: inspector, openChromium: {}
      )
      panel.model.open(inspector: inspector)
      for _ in 0..<30 where panel.model.dom.rootID == nil { await Task.yield() }
      panel.model.dom.select(5)
      let view = panel.frame(width: 1040, height: 500).environment(\.colorScheme, scheme)
      try capture(view, named: "elements-tree-\(suffix)", appearance: appearance, root: root)
      model.close()
      panel.model.close()
    }
    XCTAssertTrue(NSApp.keyWindow === previous)
  }

  private func copyPathDocument() -> [String: Any] {
    [
      "root": [
        "nodeId": 1, "nodeType": 9, "nodeName": "#document", "nodeValue": "",
        "children": [
          [
            "nodeId": 2, "nodeType": 1, "nodeName": "HTML", "nodeValue": "",
            "children": [
              [
                "nodeId": 3, "nodeType": 1, "nodeName": "BODY", "nodeValue": "",
                "children": [
                  ["nodeId": 4, "nodeType": 1, "nodeName": "SECTION", "nodeValue": ""],
                  ["nodeId": 5, "nodeType": 1, "nodeName": "SECTION", "nodeValue": ""],
                ],
              ]
            ],
          ]
        ],
      ]
    ]
  }

  private func capture<V: View>(
    _ view: V, named name: String, appearance: NSAppearance.Name, root: URL
  ) throws {
    let image = try VisualCapture.renderOffscreen(
      view, size: NSSize(width: 1040, height: 500), appearance: appearance,
      to: root.appending(path: "\(name).png"))
    XCTAssertEqual(image.pixelsWide, 1040)
    XCTAssertEqual(image.pixelsHigh, 500)
  }
}
